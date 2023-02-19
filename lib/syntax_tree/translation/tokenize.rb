# frozen_string_literal: true

module SyntaxTree
  module Translation
    # When translating to the whitequark/parser gem, it's also necessary to
    # translate the tokens in addition to the tree. This class is responsible
    # for doing that.
    class Tokenize
      KEYWORD_MAPPING = {
        __LINE__: :k__LINE__,
        __FILE__: :k__FILE__,
        __ENCODING__: :k__ENCODING__,
        BEGIN: :klBEGIN,
        END: :klEND,
        alias: :kALIAS,
        and: :kAND,
        begin: :kBEGIN,
        break: :kBREAK,
        case: :kCASE,
        class: :kCLASS,
        def: :kDEF,
        defined?: :kDEFINED,
        do: :kDO,
        else: :kELSE,
        elsif: :kELSIF,
        end: :kEND,
        ensure: :kENSURE,
        false: :kFALSE,
        for: :kFOR,
        in: :kIN,
        module: :kMODULE,
        next: :kNEXT,
        nil: :kNIL,
        not: :kNOT,
        or: :kOR,
        redo: :kREDO,
        retry: :kRETRY,
        return: :kRETURN,
        self: :kSELF,
        super: :kSUPER,
        then: :kTHEN,
        true: :kTRUE,
        undef: :kUNDEF,
        when: :kWHEN,
        yield: :kYIELD
      }.freeze

      OPERATOR_MAPPING = {
        "~" => :tTILDE,
        "?" => :tEH,
        ":" => :tCOLON,
        "!" => :tBANG,
        "!=" => :tNEQ,
        "!~" => :tNMATCH,
        "**" => :tDSTAR,
        "/" => :tDIVIDE,
        "&." => :tANDDOT,
        "&&" => :tANDOP,
        "%" => :tPERCENT,
        "^" => :tCARET,
        "+" => :tPLUS,
        "<" => :tLT,
        "<<" => :tLSHFT,
        "<=" => :tLEQ,
        "<=>" => :tCMP,
        "=" => :tEQL,
        "==" => :tEQ,
        "===" => :tEQQ,
        "=>" => :tASSOC,
        "=~" => :tMATCH,
        ">" => :tGT,
        ">=" => :tGEQ,
        ">>" => :tRSHFT,
        "|" => :tPIPE,
        "||" => :tOROP,
        "[]=" => :tASET
      }.freeze

      attr_reader :buffer, :lines

      def initialize(buffer)
        @buffer = buffer

        current = 0
        @lines = [current]

        buffer.source.each_line do |line|
          current += line.bytesize
          @lines << current
        end

        @lines << current
      end

      # This is a special API that mirrors the one from the parser gem that
      # returns a list of tokens for the given source code.
      def tokenize
        tokens = Ripper.lex(buffer.source)
        results = []

        state = Ripper::Lexer::State.new(Ripper::EXPR_BEG)
        index = 0

        heredoc_index = nil
        newline_index = nil

        while index < tokens.length
          ((lineno, column), type, value, consequent_state) = tokens[index]
          range = build_range(lineno, column, value.bytesize)

          case type
          when :on_CHAR
            results << [:tCHARACTER, [value[1..], range]]
          when :on_backref
            if value =~ /\A\$(\d+)\z/
              results << [:tNTH_REF, [$1.to_i, range]]
            else
              results << [:tBACK_REF, [value, range]]
            end
          when :on_backtick
            results << [:tXSTRING_BEG, [value, range]]
          when :on_comma
            results << [:tCOMMA, [value, range]]
          when :on_comment
            results << [:tCOMMENT, [value.chomp, build_range(lineno, column, value.bytesize - 1)]]
          when :on_const
            results << [:tCONSTANT, [value, range]]
          when :on_cvar
            results << [:tCVAR, [value, range]]
          when :on_embdoc_beg
            end_index = tokens[index..].index { _1[1] == :on_embdoc_end }

            ((lineno, column), _, value, *) = tokens[index + end_index]
            end_loc = build_range(lineno, column, value.length)

            results << [:tCOMMENT, [tokens[index..(index + end_index)].map { _1[2] }.join, range.join(end_loc)]]
            index += end_index
          when :on_embexpr_beg
            results << [:tSTRING_DBEG, [value, range]]
          when :on_embexpr_end
            results << [:tSTRING_DEND, [value, range]]
          when :on_embvar
            results << [:tSTRING_DVAR, [nil, range]]
          when :on_float
            results << [:tFLOAT, [value.to_f, range]]
          when :on_gvar
            results << [:tGVAR, [value, range]]
          when :on_heredoc_beg
            results << [:tSTRING_BEG, [value[/\A(.+?)[A-Z]/, 1], range]]
            heredoc_index = index
            index += tokens[index..].index { _1[1] == :on_nl }
          when :on_heredoc_end
            results << [:tSTRING_END, [value.chomp, build_range(lineno, column, value.bytesize - 1)]]
            newline_index = index
            index = heredoc_index
            heredoc_index = nil
          when :on_ident
            if value.end_with?("!")
              results << [:tFID, [value, range]]
            else
              results << [:tIDENTIFIER, [value, range]]
            end
          when :on_ignored_nl
            results << [:tNL, [nil, range]]
          when :on_ignored_sp
            # skip
          when :on_imaginary
            results << [:tIMAGINARY, [eval(value), range]]
          when :on_int
            if value.start_with?("+")
              results << [:tUNARY_NUM, ["+", build_range(lineno, column, 1)]]
              results << [:tINTEGER, [value.to_i, build_range(lineno, column + 1, value.bytesize - 1)]]
            else
              results << [:tINTEGER, [value.to_i, range]]
            end
          when :on_ivar
            results << [:tIVAR, [value, range]]
          when :on_label
            results << [:tLABEL, [value.chomp(":"), range]]
          when :on_lbrace
            if state == Ripper::EXPR_END
              results << [:tLCURLY, [value, range]]
            elsif state == Ripper::EXPR_ENDARG
              results << [:tLBRACE_ARG, [value, range]]
            else
              results << [:tLBRACE, [value, range]]
            end
          when :on_lbracket
            if state == Ripper::EXPR_BEG
              results << [:tLBRACK, [value, range]]
            else
              results << [:tLBRACK2, [value, range]]
            end
          when :on_lparen
            if ((state & Ripper::EXPR_BEG) == Ripper::EXPR_BEG) || state == Ripper::EXPR_MID
              results << [:tLPAREN, [value, range]]
            elsif (state == Ripper::EXPR_CMDARG || state == Ripper::EXPR_ARG) || (state == (Ripper::EXPR_END | Ripper::EXPR_LABEL))
              results << [:tLPAREN_ARG, [value, range]]
            else
              results << [:tLPAREN2, [value, range]]
            end
          when :on_kw
            case value
            when "if"
              if modifier?(state)
                results << [:kIF_MOD, [value, range]]
              else
                results << [:kIF, [value, range]]
              end
            when "rescue"
              if modifier?(state)
                results << [:kRESCUE_MOD, [value, range]]
              else
                results << [:kRESCUE, [value, range]]
              end
            when "unless"
              if modifier?(state)
                results << [:kUNLESS_MOD, [value, range]]
              else
                results << [:kUNLESS, [value, range]]
              end
            when "until"
              if modifier?(state)
                results << [:kUNTIL_MOD, [value, range]]
              else
                results << [:kUNTIL, [value, range]]
              end
            when "while"
              if modifier?(state)
                results << [:kWHILE_MOD, [value, range]]
              else
                results << [:kWHILE, [value, range]]
              end
            else
              results << [KEYWORD_MAPPING.fetch(value.to_sym), [value, range]]
            end
          when :on_label_end
            results << [:tLABEL_END, [value.chomp(":"), range]]
          when :on_nl
            results << [:tNL, [nil, range]]

            if newline_index
              index = newline_index
              newline_index = nil
            end
          when :on_op
            case value
            when "::"
              if state == Ripper::EXPR_BEG
                results << [:tCOLON3, [value, range]]
              else
                results << [:tCOLON2, [value, range]]
              end
            when "-"
              if (state & Ripper::EXPR_BEG == Ripper::EXPR_BEG) || state == Ripper::EXPR_CMDARG
                if %i[on_int on_float].include?(tokens[index + 1][1])
                  results << [:tUNARY_NUM, [value, range]]
                else
                  results << [:tUMINUS, [value, range]]
                end
              else
                results << [:tMINUS, [value, range]]
              end
            when "*"
              results << [:tSTAR, [value, range]]
            when "&"
              if state == Ripper::EXPR_BEG
                results << [:tAMPER, [value, range]]
              else
                results << [:tAMPER2, [value, range]]
              end
            when ".."
              if state == Ripper::EXPR_BEG
                results << [:tBDOT2, [value, range]]
              else
                results << [:tDOT2, [value, range]]
              end
            when "..."
              if state == Ripper::EXPR_BEG
                results << [:tBDOT3, [value, range]]
              else
                results << [:tDOT3, [value, range]]
              end
            when "+=", "|=", "||=", "&=", "&&="
              results << [:tOP_ASGN, [value.chomp("="), range]]
            else
              results << [OPERATOR_MAPPING.fetch(value), [value, range]]
            end
          when :on_period
            results << [:tDOT, [value, range]]
          when :on_qsymbols_beg
            results << [:tQSYMBOLS_BEG, [value, range]]
            index += 1 if tokens[index + 1][1] == :on_words_sep
          when :on_qwords_beg
            results << [:tQWORDS_BEG, [value, range]]
            index += 1 if tokens[index + 1][1] == :on_words_sep
          when :on_rational
            results << [:tRATIONAL, [value.to_r, range]]
          when :on_rbrace
            results << [:tRCURLY, [value, range]]
          when :on_rbracket
            results << [:tRBRACK, [value, range]]
          when :on_regexp_beg
            results << [:tREGEXP_BEG, [value, range]]
          when :on_regexp_end
            results << [:tSTRING_END, [value[0], build_range(lineno, column, 1)]]
            results << [:tREGEXP_OPT, [value[1..-1], build_range(lineno, column + 1, value.length - 1)]]
          when :on_rparen
            results << [:tRPAREN, [value, range]]
          when :on_semicolon
            results << [:tSEMI, [value, range]]
          when :on_sp
            # skip
          when :on_symbeg
            if value == ":"
              ((lineno, column), _, value, *) = tokens[index + 1]
              end_loc = build_range(lineno, column, value.length)

              results << [:tSYMBOL, [value, range.join(end_loc)]]
              index += 1
            else
              results << [:tSYMBEG, [value, range]]
            end
          when :on_symbols_beg
            results << [:tSYMBOLS_BEG, [value, range]]
            index += 1 if tokens[index + 1][1] == :on_words_sep
          when :on_tlambda
            results << [:tLAMBDA, [value, range]]
          when :on_tlambeg
            results << [:tLAMBEG, [value, range]]
          when :on_tstring_beg
            if (value == "\"" || value == "'")
              if tokens[index + 1][1] == :on_tstring_end
                ((lineno, column), _, value, *) = tokens[index + 1]
                end_loc = build_range(lineno, column, value.length)

                results << [:tSTRING, ["", range.join(end_loc)]]
                index += 1
              elsif tokens[index + 1][1] == :on_tstring_content && tokens[index + 2][1] == :on_tstring_end
                ((lineno, column), _, value, *) = tokens[index + 2]
                end_loc = build_range(lineno, column, value.length)

                results << [:tSTRING, [tokens[index + 1][2], range.join(end_loc)]]
                index += 2
              else
                results << [:tSTRING_BEG, [value, range]]
              end
            else
              results << [:tSTRING_BEG, [value, range]]
            end
          when :on_tstring_content
            results << [:tSTRING_CONTENT, [value, range]]
          when :on_tstring_end  
            results << [:tSTRING_END, [value, range]]
          when :on_words_beg
            results << [:tWORDS_BEG, [value, range]]
            index += 1 if tokens[index + 1][1] == :on_words_sep
          when :on_words_sep
            results << [:tSPACE, [nil, range]]
          else
            raise "Unknown token type: #{type.inspect}"
          end

          state = consequent_state
          index += 1
        end

        results
      end

      private

      def build_range(lineno, column, length)
        start_char = lines[lineno - 1] + column
        end_char = start_char + length

        ::Parser::Source::Range.new(buffer, start_char, end_char)
      end

      def modifier?(state)
        state != Ripper::EXPR_BEG && state != Ripper::EXPR_FNAME && state != Ripper::EXPR_CLASS
      end
    end
  end
end
