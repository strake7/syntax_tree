# frozen_string_literal: true

module SyntaxTree
  # This class can be used to build an index of the structure of Ruby files. We
  # define an index as the list of constants and methods defined within a file.
  #
  # This index strives to be as fast as possible to better support tools like
  # IDEs. Because of that, it has different backends depending on what
  # functionality is available.
  module Index
    # This is a location for an index entry.
    class Location
      attr_reader :line, :column

      def initialize(line, column)
        @line = line
        @column = column
      end
    end

    # This entry represents a class definition using the class keyword.
    class ClassDefinition
      attr_reader :nesting, :name, :superclass, :location, :comments

      def initialize(nesting, name, superclass, location, comments)
        @nesting = nesting
        @name = name
        @superclass = superclass
        @location = location
        @comments = comments
      end
    end

    # This entry represents a module definition using the module keyword.
    class ModuleDefinition
      attr_reader :nesting, :name, :location, :comments

      def initialize(nesting, name, location, comments)
        @nesting = nesting
        @name = name
        @location = location
        @comments = comments
      end
    end

    # This entry represents a method definition using the def keyword.
    class MethodDefinition
      attr_reader :nesting, :name, :location, :comments

      def initialize(nesting, name, location, comments)
        @nesting = nesting
        @name = name
        @location = location
        @comments = comments
      end
    end

    # This entry represents a singleton method definition using the def keyword
    # with a specified target.
    class SingletonMethodDefinition
      attr_reader :nesting, :name, :location, :comments

      def initialize(nesting, name, location, comments)
        @nesting = nesting
        @name = name
        @location = location
        @comments = comments
      end
    end

    # When you're using the instruction sequence backend, this class is used to
    # lazily parse comments out of the source code.
    class FileComments
      # We use the ripper library to pull out source comments.
      class Parser < Ripper
        attr_reader :comments

        def initialize(*)
          super
          @comments = {}
        end

        def on_comment(value)
          comments[lineno] = value.chomp
        end
      end

      # This represents the Ruby source in the form of a file. When it needs to
      # be read we'll read the file.
      class FileSource
        attr_reader :filepath

        def initialize(filepath)
          @filepath = filepath
        end

        def source
          File.read(filepath)
        end
      end

      # This represents the Ruby source in the form of a string. When it needs
      # to be read the string is returned.
      class StringSource
        attr_reader :source

        def initialize(source)
          @source = source
        end
      end

      attr_reader :source

      def initialize(source)
        @source = source
      end

      def comments
        @comments ||= Parser.new(source.source).tap(&:parse).comments
      end
    end

    # This class handles parsing comments from Ruby source code in the case that
    # we use the instruction sequence backend. Because the instruction sequence
    # backend doesn't provide comments (since they are dropped) we provide this
    # interface to lazily parse them out.
    class EntryComments
      include Enumerable
      attr_reader :file_comments, :location

      def initialize(file_comments, location)
        @file_comments = file_comments
        @location = location
      end

      def each(&block)
        line = location.line - 1
        result = []

        while line >= 0 && (comment = file_comments.comments[line])
          result.unshift(comment)
          line -= 1
        end

        result.each(&block)
      end
    end

    # This backend creates the index using RubyVM::InstructionSequence, which is
    # faster than using the Syntax Tree parser, but is not available on all
    # runtimes.
    class ISeqBackend
      VM_DEFINECLASS_TYPE_CLASS = 0x00
      VM_DEFINECLASS_TYPE_SINGLETON_CLASS = 0x01
      VM_DEFINECLASS_TYPE_MODULE = 0x02
      VM_DEFINECLASS_FLAG_SCOPED = 0x08
      VM_DEFINECLASS_FLAG_HAS_SUPERCLASS = 0x10

      def index(source)
        index_iseq(
          RubyVM::InstructionSequence.compile(source).to_a,
          FileComments.new(FileComments::StringSource.new(source))
        )
      end

      def index_file(filepath)
        index_iseq(
          RubyVM::InstructionSequence.compile_file(filepath).to_a,
          FileComments.new(FileComments::FileSource.new(filepath))
        )
      end

      private

      def location_for(iseq)
        code_location = iseq[4][:code_location]
        Location.new(code_location[0], code_location[1])
      end

      def find_constant_path(insns, index)
        index -= 1 while insns[index].is_a?(Integer)
        insn = insns[index]

        if insn.is_a?(Array) && insn[0] == :opt_getconstant_path
          # In this case we're on Ruby 3.2+ and we have an opt_getconstant_path
          # instruction, so we already know all of the symbols in the nesting.
          [index - 1, insn[1]]
        elsif insn.is_a?(Symbol) && insn.match?(/\Alabel_\d+/)
          # Otherwise, if we have a label then this is very likely the
          # destination of an opt_getinlinecache instruction, in which case
          # we'll walk backwards to grab up all of the constants.
          names = []

          index -= 1
          until insns[index].is_a?(Array) &&
                  insns[index][0] == :opt_getinlinecache
            if insns[index].is_a?(Array) && insns[index][0] == :getconstant
              names.unshift(insns[index][1])
            end

            index -= 1
          end

          [index - 1, names]
        else
          [index, []]
        end
      end

      def index_iseq(iseq, file_comments)
        results = []
        queue = [[iseq, []]]

        while (current_iseq, current_nesting = queue.shift)
          line = current_iseq[8]
          insns = current_iseq[13]

          insns.each_with_index do |insn, index|
            case insn
            when Integer
              line = insn
              next
            when Array
              # continue on
            else
              # skip everything else
              next
            end

            case insn[0]
            when :defineclass
              _, name, class_iseq, flags = insn
              next_nesting = current_nesting.dup

              # This is the index we're going to search for the nested constant
              # path within the declaration name.
              constant_index = index - 2

              # This is the superclass of the class being defined.
              superclass = []

              # If there is a superclass, then we're going to find it here and
              # then update the constant_index as necessary.
              if flags & VM_DEFINECLASS_FLAG_HAS_SUPERCLASS > 0
                constant_index, superclass =
                  find_constant_path(insns, index - 1)

                if superclass.empty?
                  raise NotImplementedError,
                        "superclass with non constant path on line #{line}"
                end
              end

              if (_, nesting = find_constant_path(insns, constant_index))
                # If there is a constant path in the class name, then we need to
                # handle that by updating the nesting.
                next_nesting << (nesting << name)
              else
                # Otherwise we'll add the class name to the nesting.
                next_nesting << [name]
              end

              if flags == VM_DEFINECLASS_TYPE_SINGLETON_CLASS
                # At the moment, we don't support singletons that aren't
                # defined on self. We could, but it would require more
                # emulation.
                if insns[index - 2] != [:putself]
                  raise NotImplementedError,
                        "singleton class with non-self receiver"
                end
              elsif flags & VM_DEFINECLASS_TYPE_MODULE > 0
                location = location_for(class_iseq)
                results << ModuleDefinition.new(
                  next_nesting,
                  name,
                  location,
                  EntryComments.new(file_comments, location)
                )
              else
                location = location_for(class_iseq)
                results << ClassDefinition.new(
                  next_nesting,
                  name,
                  superclass,
                  location,
                  EntryComments.new(file_comments, location)
                )
              end

              queue << [class_iseq, next_nesting]
            when :definemethod
              location = location_for(insn[2])
              results << MethodDefinition.new(
                current_nesting,
                insn[1],
                location,
                EntryComments.new(file_comments, location)
              )
            when :definesmethod
              if current_iseq[13][index - 1] != [:putself]
                raise NotImplementedError,
                      "singleton method with non-self receiver"
              end

              location = location_for(insn[2])
              results << SingletonMethodDefinition.new(
                current_nesting,
                insn[1],
                location,
                EntryComments.new(file_comments, location)
              )
            end
          end
        end

        results
      end
    end

    # This backend creates the index using the Syntax Tree parser and a visitor.
    # It is not as fast as using the instruction sequences directly, but is
    # supported on all runtimes.
    class ParserBackend
      class IndexVisitor < Visitor
        attr_reader :results, :nesting, :statements

        def initialize
          @results = []
          @nesting = []
          @statements = nil
        end

        visit_methods do
          def visit_class(node)
            names = visit(node.constant)
            nesting << names

            location =
              Location.new(node.location.start_line, node.location.start_column)

            superclass =
              if node.superclass
                visited = visit(node.superclass)

                if visited == [[]]
                  raise NotImplementedError, "superclass with non constant path"
                end

                visited
              else
                []
              end

            results << ClassDefinition.new(
              nesting.dup,
              names.last,
              superclass,
              location,
              comments_for(node)
            )

            super
            nesting.pop
          end

          def visit_const_ref(node)
            [node.constant.value.to_sym]
          end

          def visit_const_path_ref(node)
            visit(node.parent) << node.constant.value.to_sym
          end

          def visit_def(node)
            name = node.name.value.to_sym
            location =
              Location.new(node.location.start_line, node.location.start_column)

            results << if node.target.nil?
              MethodDefinition.new(
                nesting.dup,
                name,
                location,
                comments_for(node)
              )
            else
              SingletonMethodDefinition.new(
                nesting.dup,
                name,
                location,
                comments_for(node)
              )
            end
          end

          def visit_module(node)
            names = visit(node.constant)
            nesting << names

            location =
              Location.new(node.location.start_line, node.location.start_column)

            results << ModuleDefinition.new(
              nesting.dup,
              names.last,
              location,
              comments_for(node)
            )

            super
            nesting.pop
          end

          def visit_program(node)
            super
            results
          end

          def visit_statements(node)
            @statements = node
            super
          end

          def visit_var_ref(node)
            [node.value.value.to_sym]
          end
        end

        private

        def comments_for(node)
          comments = []

          body = statements.body
          line = node.location.start_line - 1
          index = body.index(node) - 1

          while index >= 0 && body[index].is_a?(Comment) &&
                  (line - body[index].location.start_line < 2)
            comments.unshift(body[index].value)
            line = body[index].location.start_line
            index -= 1
          end

          comments
        end
      end

      def index(source)
        SyntaxTree.parse(source).accept(IndexVisitor.new)
      end

      def index_file(filepath)
        index(SyntaxTree.read(filepath))
      end
    end

    # The class defined here is used to perform the indexing, depending on what
    # functionality is available from the runtime.
    INDEX_BACKEND =
      defined?(RubyVM::InstructionSequence) ? ISeqBackend : ParserBackend

    # This method accepts source code and then indexes it.
    def self.index(source, backend: INDEX_BACKEND.new)
      backend.index(source)
    end

    # This method accepts a filepath and then indexes it.
    def self.index_file(filepath, backend: INDEX_BACKEND.new)
      backend.index_file(filepath)
    end
  end
end
