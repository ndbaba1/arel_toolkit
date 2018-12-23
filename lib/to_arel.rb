require 'to_arel/version'
require 'arel'
require 'pg_query'

def symbolize_keys(hash)
  Hash[hash.map { |k, v| [k.to_sym, v] }]
end

# rubocop:disable Naming/MethodName
module ToArel
  class UnboundColumnReference < ::Arel::Nodes::SqlLiteral; end

  class Visitor
    attr_reader :object

    def accept(object)
      @object = object
      pp object
      visit(*klass_and_attributes(object))
    end

    private

    def visit(klass, attributes, context = nil)
      dispatch_method = "visit_#{klass}"
      args = [klass, attributes]
      method = method(dispatch_method)

      args = case method.arity
             when 2
               args
             when -3
               if context.nil?
                 args
               else
                 args.concat([context])
               end
             else
               raise 'unknown arity'
             end

      send dispatch_method, *args
    end

    def klass_and_attributes(object)
      [object.keys.first, object.values.first]
    end

    def visit_String(_klass, attributes, context = nil)
      case context
      when :operator
        attributes['str']
      when :const
        "'#{attributes['str']}'"
      else
        "\"#{attributes['str']}\""
      end
    end

    def visit_Integer(_klass, attributes)
      # Arel::Attributes::Integer.new attributes['ival']
      attributes['ival']
    end

    def visit_ColumnRef(_klass, attributes)
      UnboundColumnReference.new(
        attributes['fields'].map do |field|
          visit(*klass_and_attributes(field))
        end.join('.') # TODO: Join . might be a poor assumption
      )
    end

    def visit_ResTarget(_klass, attributes)
      visit(*klass_and_attributes(attributes['val']))
    end

    def visit_SubLink(_klass, attributes)
      type = attributes['subLinkType']
      case type
      when 4
        visit(*klass_and_attributes(attributes['subselect']))
      else
        raise "Unknown sublinktype: #{type}"
      end
    end

    def visit_Alias(_klass, attributes)
      attributes['aliasname']
    end

    def visit_RangeVar(_klass, attributes)
      table_alias = (visit(*klass_and_attributes(attributes['alias'])) if attributes['alias'])

      Arel::Table.new attributes['relname'], as: table_alias
    end

    def visit_A_Expr(_klass, attributes)
      case attributes['kind']
      when PgQuery::AEXPR_OP
        left = visit(*klass_and_attributes(attributes['lexpr']))
        right = visit(*klass_and_attributes(attributes['rexpr']))
        operator = visit(*klass_and_attributes(attributes['name'][0]), :operator)
        generate_comparison(left, right, operator)

      when PgQuery::AEXPR_OP_ANY
        left = visit(*klass_and_attributes(attributes['lexpr']))
        right = visit(*klass_and_attributes(attributes['rexpr']))
        right = Arel::Nodes::NamedFunction.new('ANY', [Arel.sql(right)])
        operator = visit(*klass_and_attributes(attributes['name'][0]), :operator)
        generate_comparison(left, right, operator)

      when PgQuery::AEXPR_IN
        left = visit(*klass_and_attributes(attributes['lexpr']))
        left = left.is_a?(String) ? Arel.sql(left) : left

        right = attributes['rexpr'].map do |expr|
          result = visit(*klass_and_attributes(expr))
          result.is_a?(String) ? Arel.sql(result) : result
        end

        operator = visit(*klass_and_attributes(attributes['name'][0]), :operator)
        if operator == '<>'
          Arel::Nodes::NotIn.new(left, right)
        else
          Arel::Nodes::In.new(left, right)
        end

      when PgQuery::CONSTR_TYPE_FOREIGN
        raise '?'

      when PgQuery::AEXPR_BETWEEN,
           PgQuery::AEXPR_NOT_BETWEEN,
           PgQuery::AEXPR_BETWEEN_SYM,
           PgQuery::AEXPR_NOT_BETWEEN_SYM
        raise '?'

      when PgQuery::AEXPR_NULLIF
        raise '?'

      else
        raise '?'
      end
    end

    def visit_A_Const(_klass, attributes)
      visit(*klass_and_attributes(attributes['val']), :const)
    end

    def visit_JoinExpr(_klass, attributes)
      # case node['jointype']
      # when 0
      #   if node['isNatural']
      #     output << 'NATURAL'
      #   elsif node['quals'].nil? && node['usingClause'].nil?
      #     output << 'CROSS'
      #   end
      # when 1
      #   output << 'LEFT'
      # when 2
      #   output << 'FULL'
      # when 3
      #   output << 'RIGHT'
      # end
      join_class = case attributes['jointype']
                   when 0
                     Arel::Nodes::InnerJoin
                   when 1
                     Arel::Nodes::OuterJoin
                   when 2
                     Arel::Nodes::FullOuterJoin
                   when 3
                     Arel::Nodes::RightOuterJoin
                   end

      larg = visit(*klass_and_attributes(attributes['larg']))
      rarg = visit(*klass_and_attributes(attributes['rarg']))
      quals = visit(*klass_and_attributes(attributes['quals']))

      join = join_class.new(rarg, quals)

      if larg.is_a?(Array)
        larg.concat([join])
      else
        [larg, join]
      end
    end

    def visit_FuncCall(_klass, attributes)
      args = attributes['args'].map { |arg| visit(*klass_and_attributes(arg)) }
      # funcname"=>[{"String"=>{"str"=>"sum"}}

      # TODO
      func_name = attributes['funcname'][0]['String']['str']

      case func_name
      when 'sum'
        Arel::Nodes::Sum.new args
      when 'count'
        Arel::Nodes::Count.new args
      else
        raise "? -> #{func_name}"
      end
    end

    def visit_SelectStmt(_klass, attributes)
      froms, join_sources = generate_sources(attributes['fromClause'])
      limit = generate_limit(attributes['limitCount'])
      targets = generate_targets(attributes['targetList'])
      sorts = generate_sorts(attributes['sortClause'])
      wheres = generate_wheres(attributes['whereClause'])
      offset = generate_offset(attributes['limitOffset'])

      select_manager = Arel::SelectManager.new(froms)
      select_manager.projections = targets
      select_manager.limit = limit
      select_manager.offset = offset
      select_manager.where(wheres) if wheres

      sorts.each do |sort|
        select_manager.order(sort)
      end

      join_sources.each do |join_source|
        select_manager.join(join_source.left, join_source.class).on(join_source.right)
      end

      select_manager
    end

    def visit_A_Star(_klass, _attributes)
      Arel.star
    end

    def visit_RawStmt(_klass, attributes)
      return unless (stmt = attributes['stmt'])

      visit(*klass_and_attributes(stmt))
    end

    def visit_SortBy(_klass, attributes)
      result = visit(*klass_and_attributes(attributes['node']))
      case attributes['sortby_dir']
      when 1
        Arel::Nodes::Ascending.new(result)
      when 2
        Arel::Nodes::Descending.new(result)
      else
        raise 'unknown sort direction'
      end
    end

    def visit_NullTest(klass, attributes)
      arg = visit(*klass_and_attributes(attributes['arg']))

      case attributes['nulltesttype']
      when 0
        Arel::Nodes::Equality.new(arg, nil)
      when 1
        Arel::Nodes::NotEqual.new(arg, nil)
      end
    end

    def visit_BoolExpr(klass, attributes, context = false)
      args = attributes['args'].map do |arg|
        visit(*klass_and_attributes(arg), context || true)
      end

      result = case attributes['boolop']
      when PgQuery::BOOL_EXPR_AND
        Arel::Nodes::And.new(args)

      when PgQuery::BOOL_EXPR_OR
        generate_boolean_expression(args, Arel::Nodes::Or)

      when PgQuery::BOOL_EXPR_NOT
        Arel::Nodes::Not.new(args)

      else
        raise '?'
      end

      if context
        Arel::Nodes::Grouping.new(result)
      else
        result
      end
    end

    def generate_comparison(left, right, operator)
      case operator
      when '='
        Arel::Nodes::Equality.new(left, right)
      when '<>'
        Arel::Nodes::NotEqual.new(left, right)
      when '>'
        Arel::Nodes::GreaterThan.new(left, right)
      when '>='
        Arel::Nodes::GreaterThanOrEqual.new(left, right)
      when '<'
        Arel::Nodes::LessThan.new(left, right)
      when '<='
        Arel::Nodes::LessThanOrEqual.new(left, right)
      else
        raise "Dunno operator `#{operator}`"
      end
    end

    def generate_boolean_expression(args, boolean_class)
      chain = boolean_class.new(nil, nil)

      args.each_with_index.reduce(chain) do |c, (arg, index)|
        if args.length - 1 == index
          c.right = arg
          c
        else
          new_chain = boolean_class.new(arg, nil)
          c.right = new_chain
          new_chain
        end
      end

      chain.right
    end

    def generate_offset(limit_offset)
      return if limit_offset.nil?

      visit(*klass_and_attributes(limit_offset))
    end

    def generate_wheres(where)
      return if where.nil?

      visit(*klass_and_attributes(where))
    end

    def generate_limit(count)
      return if count.nil?

      visit(*klass_and_attributes(count))
    end

    def generate_targets(list)
      return if list.nil?

      list.map { |target| visit(*klass_and_attributes(target)) }
    end

    def generate_sorts(sorts)
      return [] if sorts.nil?

      sorts.map { |sort| visit(*klass_and_attributes(sort)) }
    end

    def generate_sources(clause)
      froms = []
      join_sources = []

      if (from_clauses = clause)
        results = from_clauses.map { |from_clause| visit(*klass_and_attributes(from_clause)) }
          .flatten

        results.each do |result|
          if result.is_a?(Arel::Table)
            froms << result
          else
            join_sources << result
          end
        end
      end

      if froms.empty?
        [nil, join_sources]
      else
        [froms, join_sources]
      end
    end
  end

  class Error < StandardError; end
  class MultiTableError < Error; end

  def self.parse(sql)
    tree = PgQuery.parse(sql).tree
    puts tree

    Visitor.new.accept(tree.first) # DUNNO Y .first
  end

  def self.manager_from_statement(statement)
    type = statement.keys.first
    ast = statement[type]

    case type
    when 'SelectStmt'
      create_select_manager(ast)
    else
      raise "unknown statement type `#{type}`"
    end
  end

  def self.create_select_manager(ast)
    # from_clauses = ast.fetch('fromClause')
    # raise MultiTableError, 'Can not handle multiple tables' if from_clauses.length > 1
    # from_clause = from_clauses.first
    # table = RangeVar.new(**symbolize_keys(from_clause.fetch('RangeVar'))).to_arel

    # puts ast

    # target_lists = ast.fetch('targetList').map do |target_list|
    #   ResTarget.new(**symbolize_keys(target_list.fetch('ResTarget'))).to_arel
    # end

    # a = Arel::SelectManager.new table
    # b = a.project(target_lists)
    # binding.pry
  end
end
# rubocop:enable Naming/MethodName
