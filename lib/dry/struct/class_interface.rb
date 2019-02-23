require 'dry/core/class_attributes'
require 'dry/core/inflector'
require 'dry/core/descendants_tracker'

require 'dry/struct/errors'
require 'dry/struct/constructor'
require 'dry/struct/sum'

module Dry
  class Struct
    # Class-level interface of {Struct} and {Value}
    module ClassInterface
      include Core::ClassAttributes

      include Dry::Types::Type
      include Dry::Types::Builder

      # @param [Class] klass
      def inherited(klass)
        super

        base = self

        klass.class_eval do
          @meta = base.meta

          unless equal?(Value)
            extend Dry::Core::DescendantsTracker
          end
        end
      end

      # Adds an attribute for this {Struct} with given `name` and `type`
      # and modifies {.schema} accordingly.
      #
      # @param [Symbol] name name of the defined attribute
      # @param [Dry::Types::Definition, nil] type or superclass of nested type
      # @return [Dry::Struct]
      # @yield
      #   If a block is given, it will be evaluated in the context of
      #   a new struct class, and set as a nested type for the given
      #   attribute. A class with a matching name will also be defined for
      #   the nested type.
      # @raise [RepeatedAttributeError] when trying to define attribute with the
      #   same name as previously defined one
      #
      # @example with nested structs
      #   class Language < Dry::Struct
      #     attribute :name, Types::String
      #     attribute :details, Dry::Struct do
      #       attribute :type, Types::String
      #     end
      #   end
      #
      #   Language.schema
      #     #=> {
      #           :name=>#<Dry::Types::Definition primitive=String options={} meta={}>,
      #           :details=>Language::Details
      #         }
      #
      #   ruby = Language.new(name: 'Ruby', details: { type: 'OO' })
      #   ruby.name #=> 'Ruby'
      #   ruby.details #=> #<Language::Details type="OO">
      #   ruby.details.type #=> 'OO'
      #
      # @example with a nested array of structs
      #   class Language < Dry::Struct
      #     attribute :name, Types::String
      #     array :versions, Types::String
      #     array :celebrities, Types::Array.of(Dry::Struct) do
      #       attribute :name, Types::String
      #       attribute :pseudonym, Types::String
      #     end
      #   end
      #
      #   Language.schema
      #     #=> {
      #           :name=>#<Dry::Types::Definition primitive=String options={} meta={}>,
      #           :versions=>#<Dry::Types::Array::Member primitive=Array options={:member=>#<Dry::Types::Definition primitive=String options={} meta={}>} meta={}>,
      #           :celebrities=>#<Dry::Types::Array::Member primitive=Array options={:member=>Language::Celebrity} meta={}>
      #         }
      #
      #   ruby = Language.new(
      #     name: 'Ruby',
      #     versions: %w(1.8.7 1.9.8 2.0.1),
      #     celebrities: [
      #       { name: 'Yukihiro Matsumoto', pseudonym: 'Matz' },
      #       { name: 'Aaron Patterson', pseudonym: 'tenderlove' }
      #     ]
      #   )
      #   ruby.name #=> 'Ruby'
      #   ruby.versions #=> ['1.8.7', '1.9.8', '2.0.1']
      #   ruby.celebrities
      #     #=> [
      #           #<Language::Celebrity name='Yukihiro Matsumoto' pseudonym='Matz'>,
      #           #<Language::Celebrity name='Aaron Patterson' pseudonym='tenderlove'>
      #         ]
      #   ruby.celebrities[0].name #=> 'Yukihiro Matsumoto'
      #   ruby.celebrities[0].pseudonym #=> 'Matz'
      #   ruby.celebrities[1].name #=> 'Aaron Patterson'
      #   ruby.celebrities[1].pseudonym #=> 'tenderlove'
      def attribute(name, type = nil, &block)
        attributes(name => build_type(name, type, &block))
      end

      # Adds an omittable (key is not required on initialization) attribute for this {Struct}
      #
      # @example
      #   class User < Dry::Struct
      #     attribute  :name,  Types::Strict::String
      #     attribute? :email, Types::Strict::String
      #   end
      #
      #   User.new(name: 'John') # => #<User name="John">
      #
      # @param [Symbol] name name of the defined attribute
      # @param [Dry::Types::Definition, nil] type or superclass of nested type
      # @return [Dry::Struct]
      #
      def attribute?(*args, &block)
        if args.size == 1 && block.nil?
          Dry::Core::Deprecations.warn(
            'Dry::Struct.attribute? is deprecated for checking attribute presence, '\
            'use has_attribute? instead',
            tag: :'dry-struct'
          )

          has_attribute?(args[0])
        else
          name, type = args

          attribute(name, build_type(name, type, &block).meta(omittable: true))
        end
      end

      # @param [Hash{Symbol => Dry::Types::Definition}] new_schema
      # @return [Dry::Struct]
      # @raise [RepeatedAttributeError] when trying to define attribute with the
      #   same name as previously defined one
      # @see #attribute
      # @example
      #   class Book < Dry::Struct
      #     attributes(
      #       title: Types::String,
      #       author: Types::String
      #     )
      #   end
      #
      #   Book.schema
      #     #=> {title: #<Dry::Types::Definition primitive=String options={}>,
      #     #    author: #<Dry::Types::Definition primitive=String options={}>}
      def attributes(new_schema)
        check_schema_duplication(new_schema)

        schema schema.schema(new_schema)

        new_schema.each_key do |key|
          next if instance_methods.include?(key)
          class_eval(<<-RUBY)
            def #{ key }
              @attributes[#{ key.inspect }]
            end
          RUBY
        end

        @attribute_names = nil

        descendants.
          select { |d| d.superclass == self }.
          each { |d| d.attributes(new_schema.reject { |k, _| d.schema.key?(k) }) }

        self
      end

      # Add an arbitrary transformation for new attribute types.
      #
      # @param [#call,nil] proc
      # @param [#call,nil] block
      # @example
      #   class Book < Dry::Struct
      #     transform_types { |t| t.meta(struct: :Book) }
      #
      #     attribute :title, Types::Strict::String
      #   end
      #
      #   Book.schema.key(:title).meta # => { struct: :Book }
      #
      def transform_types(proc = nil, &block)
        schema schema.with_type_transform(proc || block)
      end

      # Add an arbitrary transformation for input hash keys.
      #
      # @param [#call,nil] proc
      # @param [#call,nil] block
      # @example
      #   class Book < Dry::Struct
      #     transform_keys(&:to_sym)
      #
      #     attribute :title, Types::Strict::String
      #   end
      #
      #   Book.new('title' => "The Old Man and the Sea")
      #   # => #<Book title="The Old Man and the Sea">
      def transform_keys(proc = nil, &block)
        schema schema.with_key_transform(proc || block)
      end

      # @param [Hash{Symbol => Dry::Types::Definition, Dry::Struct}] new_schema
      # @raise [RepeatedAttributeError] when trying to define attribute with the
      #   same name as previously defined one
      def check_schema_duplication(new_schema)
        overlapping_keys = new_schema.keys & (attribute_names - superclass.attribute_names)

        if overlapping_keys.any?
          raise RepeatedAttributeError, overlapping_keys.first
        end
      end
      private :check_schema_duplication

      # @param [Hash{Symbol => Object},Dry::Struct] attributes
      # @raise [Struct::Error] if the given attributes don't conform {#schema}
      def new(attributes = default_attributes)
        if attributes.instance_of?(self)
          attributes
        else
          super(schema[attributes])
        end
      rescue Types::SchemaError, Types::MissingKeyError, Types::UnknownKeysError => error
        raise Struct::Error, "[#{self}.new] #{error}"
      end

      # Calls type constructor. The behavior is identical to `.new` but returns
      # the input back if it's a subclass of the struct.
      #
      # @param [Hash{Symbol => Object},Dry::Struct] attributes
      # @return [Dry::Struct]
      def call(attributes = default_attributes)
        return attributes if attributes.is_a?(self)
        new(attributes)
      end
      alias_method :[], :call

      # @param [#call,nil] constructor
      # @param [Hash] _options
      # @param [#call,nil] block
      # @return [Dry::Struct::Constructor]
      def constructor(constructor = nil, **_options, &block)
        Struct::Constructor.new(self, fn: constructor || block)
      end

      # @param [Hash{Symbol => Object},Dry::Struct] input
      # @yieldparam [Dry::Types::Result::Failure] failure
      # @yieldreturn [Dry::Types::ResultResult]
      # @return [Dry::Types::Result]
      def try(input)
        Types::Result::Success.new(self[input])
      rescue Struct::Error => e
        failure = Types::Result::Failure.new(input, e.message)
        block_given? ? yield(failure) : failure
      end

      # @param [Hash{Symbol => Object},Dry::Struct] input
      # @return [Dry::Types::Result]
      # @private
      def try_struct(input)
        if input.is_a?(self)
          Types::Result::Success.new(input)
        else
          yield
        end
      end

      # @param [({Symbol => Object})] args
      # @return [Dry::Types::Result::Success]
      def success(*args)
        result(Types::Result::Success, *args)
      end

      # @param [({Symbol => Object})] args
      # @return [Dry::Types::Result::Failure]
      def failure(*args)
        result(::Dry::Types::Result::Failure, *args)
      end

      # @param [Class] klass
      # @param [({Symbol => Object})] args
      def result(klass, *args)
        klass.new(*args)
      end

      # @return [false]
      def default?
        false
      end

      # @param [Object, Dry::Struct] value
      # @return [Boolean]
      def valid?(value)
        self === value
      end

      # @return [true]
      def constrained?
        true
      end

      # @return [self]
      def primitive
        self
      end

      # @return [false]
      def optional?
        false
      end

      # Checks if this {Struct} has the given attribute
      #
      # @param [Symbol] key Attribute name
      # @return [Boolean]
      def has_attribute?(key)
        schema.key?(key)
      end

      # Gets the list of attribute names
      #
      # @return [Array<Symbol>]
      def attribute_names
        @attribute_names ||= schema.map(&:name)
      end

      # @return [{Symbol => Object}]
      def meta(meta = Undefined)
        if meta.equal?(Undefined)
          @meta
        else
          Class.new(self) do
            @meta = @meta.merge(meta) unless meta.empty?
          end
        end
      end

      # Build a sum type
      # @param [Dry::Types::Type] type
      # @return [Dry::Types::Sum]
      def |(type)
        if type.is_a?(Class) && type <= Struct
          Struct::Sum.new(self, type)
        else
          super
        end
      end

      # Stores an object for building nested struct classes
      # @return [StructBuilder]
      def struct_builder
        @struct_builder ||= StructBuilder.new(self).freeze
      end
      private :struct_builder

      # Retrieves default attributes from defined {.schema}.
      # Used in a {Struct} constructor if no attributes provided to {.new}
      #
      # @return [Hash{Symbol => Object}]
      def default_attributes(default_schema = schema)
        default_schema.each_with_object({}) do |key, result|
          result[key.name] = default_attributes(key.schema) if struct?(key.type)
        end
      end
      private :default_attributes

      # Checks if the given type is a Dry::Struct
      #
      # @param [Dry::Types::Definition, Dry::Struct] type
      # @return [Boolean]
      def struct?(type)
        type.is_a?(Class) && type <= Struct
      end
      private :struct?

      # Constructs a type
      #
      # @return [Dry::Types::Type, Dry::Struct]
      def build_type(name, type, &block)
        type_object =
          if type.is_a?(String)
            Dry::Types[type]
          elsif block.nil? && type.nil?
            raise(
              ArgumentError,
              'you must supply a type or a block to `Dry::Struct.attribute`'
            )
          else
            type
          end

        if block
          struct_builder.(name, type_object, &block)
        else
          type_object
        end
      end
      private :build_type
    end
  end
end
