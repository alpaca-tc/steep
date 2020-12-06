module Steep
  module Interface
    class Block
      attr_reader :type
      attr_reader :optional

      def initialize(type:, optional:)
        @type = type
        @optional = optional
      end

      def optional?
        @optional
      end

      def to_optional
        self.class.new(
          type: type,
          optional: true
        )
      end

      def ==(other)
        other.is_a?(self.class) && other.type == type && other.optional == optional
      end

      alias eql? ==

      def hash
        type.hash ^ optional.hash
      end

      def closed?
        type.closed?
      end

      def subst(s)
        ty = type.subst(s)
        if ty == type
          self
        else
          self.class.new(
            type: ty,
            optional: optional
          )
        end
      end

      def free_variables()
        @fvs ||= type.free_variables
      end

      def to_s
        "#{optional? ? "?" : ""}{ #{type.params} -> #{type.return_type} }"
      end

      def map_type(&block)
        self.class.new(
          type: type.map_type(&block),
          optional: optional
        )
      end

      def +(other)
        optional = self.optional? || other.optional?
        type = AST::Types::Proc.new(
          params: self.type.params + other.type.params,
          return_type: AST::Types::Union.build(types: [self.type.return_type, other.type.return_type])
        )
        self.class.new(
          type: type,
          optional: optional
        )
      end
    end

    class MethodType
      attr_reader :type_params
      attr_reader :params
      attr_reader :block
      attr_reader :return_type
      attr_reader :method_decls

      def initialize(type_params:, params:, block:, return_type:, method_decls:)
        @type_params = type_params
        @params = params
        @block = block
        @return_type = return_type
        @method_decls = method_decls
      end

      def ==(other)
        other.is_a?(self.class) &&
          other.type_params == type_params &&
          other.params == params &&
          other.block == block &&
          other.return_type == return_type
      end

      alias eql? ==

      def hash
        type_params.hash ^ params.hash ^ block.hash ^ return_type.hash
      end

      def free_variables
        @fvs ||= Set.new.tap do |set|
          set.merge(params.free_variables)
          if block
            set.merge(block.free_variables)
          end
          set.merge(return_type.free_variables)
          set.subtract(type_params)
        end
      end

      def subst(s)
        return self if s.empty?
        return self if free_variables.disjoint?(s.domain)

        s_ = s.except(type_params)

        self.class.new(
          type_params: type_params,
          params: params.subst(s_),
          block: block&.subst(s_),
          return_type: return_type.subst(s_),
          method_decls: method_decls
        )
      end

      def each_type(&block)
        if block_given?
          params.each_type(&block)
          self.block&.tap do
            self.block.type.params.each_type(&block)
            yield(self.block.type.return_type)
          end
          yield(return_type)
        else
          enum_for :each_type
        end
      end

      def instantiate(s)
        self.class.new(type_params: [],
                       params: params.subst(s),
                       block: block&.subst(s),
                       return_type: return_type.subst(s),
                       method_decls: method_decls)
      end

      def with(type_params: self.type_params, params: self.params, block: self.block, return_type: self.return_type, method_decls: self.method_decls)
        self.class.new(type_params: type_params,
                       params: params,
                       block: block,
                       return_type: return_type,
                       method_decls: method_decls)
      end

      def to_s
        type_params = !self.type_params.empty? ? "[#{self.type_params.map{|x| "#{x}" }.join(", ")}] " : ""
        params = self.params.to_s
        block = self.block ? " #{self.block}" : ""

        "#{type_params}#{params}#{block} -> #{return_type}"
      end

      def map_type(&block)
        self.class.new(type_params: type_params,
                       params: params.map_type(&block),
                       block: self.block&.yield_self {|blk| blk.map_type(&block) },
                       return_type: yield(return_type),
                       method_decls: method_decls)
      end

      # Returns a new method type which can be used for the method implementation type of both `self` and `other`.
      #
      def unify_overload(other)
        type_params = []
        s1 = Substitution.build(self.type_params)
        type_params.push(*s1.dictionary.values.map(&:name))
        s2 = Substitution.build(other.type_params)
        type_params.push(*s2.dictionary.values.map(&:name))

        block = case
                when self.block && other.block
                  self.block.subst(s1) + other.block.subst(s2)
                when self.block
                  self.block.to_optional.subst(s1)
                when other.block
                  other.block.to_optional.subst(s2)
                end

        self.class.new(
          type_params: type_params,
          params: params.subst(s1) + other.params.subst(s2),
          block: block,
          return_type: AST::Types::Union.build(
            types: [return_type.subst(s1),other.return_type.subst(s2)]
          ),
          method_decls: method_decls + other.method_decls
        )
      end

      def +(other)
        unify_overload(other)
      end

      # Returns a method type which is a super-type of both self and other.
      #   self <: (self | other) && other <: (self | other)
      #
      # Returns nil if self and other are incompatible.
      #
      def |(other)
        self_type_params = Set.new(self.type_params)
        other_type_params = Set.new(other.type_params)

        unless (common_type_params = (self_type_params & other_type_params).to_a).empty?
          fresh_types = common_type_params.map {|name| AST::Types::Var.fresh(name) }
          fresh_names = fresh_types.map(&:name)
          subst = Substitution.build(common_type_params, fresh_types)
          other = other.instantiate(subst)
          type_params = (self_type_params + (other_type_params - common_type_params + Set.new(fresh_names))).to_a
        else
          type_params = (self_type_params + other_type_params).to_a
        end

        params = self.params & other.params or return
        block = case
                when self.block && other.block
                  block_params = self.block.type.params | other.block.type.params
                  block_return_type = AST::Types::Intersection.build(types: [self.block.type.return_type, other.block.type.return_type])
                  block_type = AST::Types::Proc.new(params: block_params,
                                                    return_type: block_return_type,
                                                    location: nil)
                  Block.new(
                    type: block_type,
                    optional: self.block.optional && other.block.optional
                  )
                when self.block && self.block.optional?
                  self.block
                when other.block && other.block.optional?
                  other.block
                when !self.block && !other.block
                  nil
                else
                  return
                end
        return_type = AST::Types::Union.build(types: [self.return_type, other.return_type])

        MethodType.new(
          params: params,
          block: block,
          return_type: return_type,
          type_params: type_params,
          method_decls: method_decls + other.method_decls
        )
      end

      # Returns a method type which is a sub-type of both self and other.
      #   (self & other) <: self && (self & other) <: other
      #
      # Returns nil if self and other are incompatible.
      #
      def &(other)
        self_type_params = Set.new(self.type_params)
        other_type_params = Set.new(other.type_params)

        unless (common_type_params = (self_type_params & other_type_params).to_a).empty?
          fresh_types = common_type_params.map {|name| AST::Types::Var.fresh(name) }
          fresh_names = fresh_types.map(&:name)
          subst = Substitution.build(common_type_params, fresh_types)
          other = other.subst(subst)
          type_params = (self_type_params + (other_type_params - common_type_params + Set.new(fresh_names))).to_a
        else
          type_params = (self_type_params + other_type_params).to_a
        end

        params = self.params | other.params
        block = case
                when self.block && other.block
                  block_params = self.block.type.params & other.block.type.params or return
                  block_return_type = AST::Types::Union.build(types: [self.block.type.return_type, other.block.type.return_type])
                  block_type = AST::Types::Proc.new(params: block_params,
                                                    return_type: block_return_type,
                                                    location: nil)
                  Block.new(
                    type: block_type,
                    optional: self.block.optional || other.block.optional
                  )

                else
                  self.block || other.block
                end

        return_type = AST::Types::Intersection.build(types: [self.return_type, other.return_type])

        MethodType.new(
          params: params,
          block: block,
          return_type: return_type,
          type_params: type_params,
          method_decls: method_decls + other.method_decls
        )
      end
    end
  end
end
