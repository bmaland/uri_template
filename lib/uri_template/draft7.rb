# -*- encoding : utf-8 -*-
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the Affero GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
#    (c) 2011 by Hannes Georg
#

require 'strscan'
require 'set'
require 'forwardable'

require 'uri_template'
require 'uri_template/utils'

# A uri template which should comply with the uri template spec draft 7 ( http://tools.ietf.org/html/draft-gregorio-uritemplate-07 ).
# @note
#   Most specs and examples refer to this class directly, because they are acutally refering to this specific implementation. If you just want uri templates, you should rather use the methods on {URITemplate} to create templates since they will select an implementation.
class URITemplate::Draft7

  include URITemplate
  extend Forwardable
  
  # @private
  Utils = URITemplate::Utils
  
  # @private
  LITERAL = /^([^"'%<>\\^`{|}\s\p{Cc}]|%\h\h)+/
  
  # @private
  CHARACTER_CLASSES = {
  
    :unreserved => {
      :unencoded => /([^A-Za-z0-9\-\._])/,
      :class => '(?<c_u_>[A-Za-z0-9\-\._]|%\h\h)',
      :class_name => 'c_u_',
      :grabs_comma => false
    },
    :unreserved_reserved_pct => {
      :unencoded => /([^A-Za-z0-9\-\._:\/?#\[\]@!\$%'\(\)*+,;=]|%(?!\h\h))/,
      :class => '(?<c_urp_>[A-Za-z0-9\-\._:\/?#\[\]@!\$%\'\(\)*+,;=]|%\h\h)',
      :class_name => 'c_urp_',
      :grabs_comma => true
    },
    
    :varname => {
      :class => '(?<c_vn_> (?:[a-zA-Z_]|%[0-9a-fA-F]{2})(?:[a-zA-Z_\.]|%[0-9a-fA-F]{2})*?)',
      :class_name => 'c_vn_'
    }
  
  }
  
  # Specifies that no processing should be done upon extraction.
  # @see #extract
  NO_PROCESSING = []
  
  # Specifies that the extracted values should be processed.
  # @see #extract
  CONVERT_VALUES = [:convert_values]
  
  # Specifies that the extracted variable list should be processed.
  # @see #extract
  CONVERT_RESULT = [:convert_result]
  
  # Default processing. Means: convert values and the list itself.
  # @see #extract
  DEFAULT_PROCESSING = CONVERT_VALUES + CONVERT_RESULT
  
  # @private
  VAR = Regexp.compile(<<'__REGEXP__'.strip, Regexp::EXTENDED)
(?<operator> [+#\./;?&]?){0}
(?<varchar> [a-zA-Z_]|%[0-9a-fA-F]{2}){0}
(?<varname> \g<varchar>(?:\g<varchar>|\.)*){0}
(?<varspec> \g<varname>(?<explode>\*?)(?::(?<length>\d+))?){0}
\g<varspec>
__REGEXP__
  
  # @private
  EXPRESSION = Regexp.compile(<<'__REGEXP__'.strip, Regexp::EXTENDED)
(?<operator> [+#\./;?&]?){0}
(?<varchar> [a-zA-Z_]|%[0-9a-fA-F]{2}){0}
(?<varname> \g<varchar>(?:\g<varchar>|\.)*){0}
(?<varspec> \g<varname>\*?(?::\d+)?){0}
\{\g<operator>(?<vars>\g<varspec>(?:,\g<varspec>)*)\}
__REGEXP__

  # @private
  URI = Regexp.compile(<<'__REGEXP__'.strip, Regexp::EXTENDED)
(?<operator> [+#\./;?&]?){0}
(?<varchar> [a-zA-Z_]|%[0-9a-fA-F]{2}){0}
(?<varname> \g<varchar>(?:\g<varchar>|\.)*){0}
(?<varspec> \g<varname>\*?(?::\d+)?){0}
^(([^"'%<>^`{|}\s\p{Cc}]|%\h\h)+|\{\g<operator>(?<vars>\g<varspec>(?:,\g<varspec>)*)\})*$
__REGEXP__
  
  # @private
  class Token
  end
  
  # @private
  class Literal < Token
  
    attr_reader :string
  
    def initialize(string)
      @string = string
    end
    
    def size
      0
    end
    
    def level
      1
    end
    
    def expand(*_)
      return @string
    end
    
    def to_r_source(*_)
      Regexp.escape(@string)
    end
    
    def to_s
      @string
    end
    
  end

  # @private
  class Expression < Token
    
    attr_reader :variables, :max_length
    
    def initialize(vars)
      @variables = vars
    end
    
    PREFIX = ''.freeze
    SEPARATOR = ','.freeze
    PAIR_CONNECTOR = '='.freeze
    PAIR_IF_EMPTY = true
    LIST_CONNECTOR = ','.freeze
    BASE_LEVEL = 1
    
    CHARACTER_CLASS = CHARACTER_CLASSES[:unreserved]
    
    NAMED = false
    OPERATOR = ''
    
    def size
      @variables.size
    end
    
    def level
      if @variables.none?{|_,expand,ml| expand || (ml > 0) }
        if @variables.size == 1
          return self.class::BASE_LEVEL
        else
          return 3
        end
      else
        return 4
      end
    end
    
    def expand( vars, options )
      result = []
      variables.each{| var, expand , max_length |
        unless vars[var].nil?
          if vars[var].kind_of? Hash
            result.push( *transform_hash(var, vars[var], expand, max_length) )
          elsif vars[var].kind_of? Array
            result.push( *transform_array(var, vars[var], expand, max_length) )
          else
            if self.class::NAMED
              result.push( pair(var, vars[var], max_length) )
            else
              result.push( cut( encode(vars[var]), max_length ) )
            end
          end
        end
      }
      if result.any?
        return (self.class::PREFIX + result.join(self.class::SEPARATOR))
      else
        return ''
      end
    end
    
    def to_s
      '{' + self.class::OPERATOR +  @variables.map{|name,expand,max_length| name +(expand ? '*': '') + (max_length > 0 ? ':'+max_length.to_s : '') }.join(',') + '}'
    end
    
    #TODO: certain things after a slurpy variable will never get matched. therefore, it's pointless to add expressions for them
    #TODO: variables, which appear twice could be compacted, don't they?
    def to_r_source(base_counter = 0)
      source = []
      first = true
      vs = variables.size - 1
      i = 0
      if self.class::NAMED
        variables.each{| var, expand , max_length |
          last = (vs == i)
          value = "(?:\\g<#{self.class::CHARACTER_CLASS[:class_name]}>|,)#{(max_length > 0)?'{,'+max_length.to_s+'}':'*'}"
          if expand
            #if self.class::PAIR_IF_EMPTY
            pair = "(?:\\g<c_vn_>#{Regexp.escape(self.class::PAIR_CONNECTOR)})?#{value}"
            
            if first
              source << "(?<v#{base_counter + i}>(?:#{pair})(?:#{Regexp.escape(self.class::SEPARATOR)}#{pair})*)"
            else
              source << "(?<v#{base_counter + i}>(?:#{Regexp.escape(self.class::SEPARATOR)}#{pair})*)"
            end
          else
            if self.class::PAIR_IF_EMPTY
              pair = "#{Regexp.escape(var)}(?<v#{base_counter + i}>#{Regexp.escape(self.class::PAIR_CONNECTOR)}#{value})?"
            else
              pair = "#{Regexp.escape(var)}(?<v#{base_counter + i}>#{Regexp.escape(self.class::PAIR_CONNECTOR)}#{value}|)"
            end
            
            if first
            source << "(?:#{pair})"
            else
              source << "(?:#{Regexp.escape(self.class::SEPARATOR)}#{pair})?"
            end
          end
          
          first = false
          i = i+1
        }
      else
        variables.each{| var, expand , max_length |
          last = (vs == i)
          if expand
            # could be list or map, too
            value = "\\g<#{self.class::CHARACTER_CLASS[:class_name]}>#{(max_length > 0)?'{,'+max_length.to_s+'}':'*'}"
            
            pair = "(?:\\g<c_vn_>#{Regexp.escape(self.class::PAIR_CONNECTOR)})?#{value}"
            
            value = "#{pair}(?:#{Regexp.escape(self.class::SEPARATOR)}#{pair})*"
          elsif last
            # the last will slurp lists
            if self.class::CHARACTER_CLASS[:grabs_comma]
              value = "(?:\\g<#{self.class::CHARACTER_CLASS[:class_name]}>)#{(max_length > 0)?'{,'+max_length.to_s+'}':'*?'}"
            else
              value = "(?:\\g<#{self.class::CHARACTER_CLASS[:class_name]}>|,)#{(max_length > 0)?'{,'+max_length.to_s+'}':'*?'}"
            end
          else
            value = "\\g<#{self.class::CHARACTER_CLASS[:class_name]}>#{(max_length > 0)?'{,'+max_length.to_s+'}':'*?'}"
          end
          if first
            source << "(?<v#{base_counter + i}>#{value})"
            first = false
          else
            source << "(?:#{Regexp.escape(self.class::SEPARATOR)}(?<v#{base_counter + i}>#{value}))?"
          end
          i = i+1
        }
      end
      return '(?:' + Regexp.escape(self.class::PREFIX) + source.join + ')?'
    end
    
    def extract(position,matched)
      name, expand, max_length = @variables[position]
      if matched.nil?
        return [[ name , matched ]]
      end
      if expand
        ex = self.hash_extractor(max_length)
        rest = matched
        splitted = []
        found_value = false
        until rest.size == 0
          match = ex.match(rest)
          if match.nil?
            raise "Couldn't match #{rest.inspect} againts the hash extractor. This is definitly a Bug. Please report this ASAP!"
          end
          if match.post_match.size == 0
            rest = match['rest'].to_s
          else
            rest = ''
          end
          if match['name']
            found_value = true
            splitted << [ match['name'][0..-2], decode(match['value'] + rest , false) ]
          else
            splitted << [ match['value'] + rest, nil ]
          end
          rest = match.post_match
        end
        if !found_value
          return [ [ name, splitted.map{|n,v| decode(n , false) } ] ]
        else
          return [ [ name, splitted ] ]
        end
      elsif self.class::NAMED
        return [ [ name, decode( matched[1..-1] ) ] ]
      end
      
      return [ [ name,  decode( matched ) ] ]
    end
    
    def variable_names
      @variables.collect(&:first)
    end
     
  protected
    
    def hash_extractor(max_length)
      value = "\\g<#{self.class::CHARACTER_CLASS[:class_name]}>#{(max_length > 0)?'{,'+max_length.to_s+'}':'*?'}"
      
      pair = "(?<name>\\g<c_vn_>#{Regexp.escape(self.class::PAIR_CONNECTOR)})?(?<value>#{value})"
      
      return Regexp.new( CHARACTER_CLASSES[:varname][:class] + "{0}\n" + self.class::CHARACTER_CLASS[:class] + "{0}\n"  + "^#{Regexp.escape(self.class::SEPARATOR)}?" + pair + "(?<rest>$|#{Regexp.escape(self.class::SEPARATOR)}(?!#{Regexp.escape(self.class::SEPARATOR)}))" ,Regexp::EXTENDED)
      
    end
    
    def encode(x)
      Utils.pct(Utils.object_to_param(x), self.class::CHARACTER_CLASS[:unencoded])
    end
    
    SPLITTER = /^(?:,(,*)|([^,]+))/
    
    def decode(x, split = true)
      if x.nil?
        if self.class::PAIR_IF_EMPTY
          return x
        else
          return ''
        end
      elsif split
        r = []
        v = x
        until v.size == 0
          m = SPLITTER.match(v)
          if m[1] and m[1].size > 0
            r << m[1]
          elsif m[2]
            r << Utils.dpct(m[2])
          end
          v = m.post_match
        end
        case(r.size)
          when 0 then ''
          when 1 then r.first
          else r
        end
      else
        Utils.dpct(x)
      end
    end
    
    def cut(str,chars)
      if chars > 0
        md = Regexp.compile("^#{self.class::CHARACTER_CLASS[:class]}{,#{chars.to_s}}", Regexp::EXTENDED).match(str)
        #TODO: handle invalid matches
        return md[0]
      else
        return str
      end
    end
    
    def pair(key, value, max_length = 0)
      ek = encode(key)
      ev = encode(value)
      if !self.class::PAIR_IF_EMPTY and ev.size == 0
        return ek
      else
        return ek + self.class::PAIR_CONNECTOR + cut( ev, max_length )
      end
    end
    
    def transform_hash(name, hsh, expand , max_length)
      if expand
        hsh.map{|key,value| pair(key,value) }
      elsif hsh.none?
        []
      else
        [ (self.class::NAMED ? encode(name)+self.class::PAIR_CONNECTOR : '' ) + hsh.map{|key,value| encode(key)+self.class::LIST_CONNECTOR+encode(value) }.join(self.class::LIST_CONNECTOR) ]
      end
    end
    
    def transform_array(name, ary, expand , max_length)
      if expand
        ary.map{|value| encode(value) }
      elsif ary.none?
        []
      else
        [ (self.class::NAMED ? encode(name)+self.class::PAIR_CONNECTOR : '' ) + ary.map{|value| encode(value) }.join(self.class::LIST_CONNECTOR) ]
      end
    end
    
    class Reserved < self
    
      CHARACTER_CLASS = CHARACTER_CLASSES[:unreserved_reserved_pct]
      OPERATOR = '+'.freeze
      BASE_LEVEL = 2
    
    end
    
    class Fragment < self
    
      CHARACTER_CLASS = CHARACTER_CLASSES[:unreserved_reserved_pct]
      PREFIX = '#'.freeze
      OPERATOR = '#'.freeze
      BASE_LEVEL = 2
    
    end
    
    class Label < self
    
      SEPARATOR = '.'.freeze
      PREFIX = '.'.freeze
      OPERATOR = '.'.freeze
      BASE_LEVEL = 3
    
    end
    
    class Path < self
    
      SEPARATOR = '/'.freeze
      PREFIX = '/'.freeze
      OPERATOR = '/'.freeze
      BASE_LEVEL = 3
    
    end
    
    class PathParameters < self
    
      SEPARATOR = ';'.freeze
      PREFIX = ';'.freeze
      NAMED = true
      PAIR_IF_EMPTY = false
      OPERATOR = ';'.freeze
      BASE_LEVEL = 3
    
    end
    
    class FormQuery < self
    
      SEPARATOR = '&'.freeze
      PREFIX = '?'.freeze
      NAMED = true
      OPERATOR = '?'.freeze
      BASE_LEVEL = 3
    
    end
    
    class FormQueryContinuation < self
    
      SEPARATOR = '&'.freeze
      PREFIX = '&'.freeze
      NAMED = true
      OPERATOR = '&'.freeze
      BASE_LEVEL = 3
    
    end
    
  end
  
  # @private
  OPERATORS = {
    ''  => Expression,
    '+' => Expression::Reserved,
    '#' => Expression::Fragment,
    '.' => Expression::Label,
    '/' => Expression::Path,
    ';' => Expression::PathParameters,
    '?' => Expression::FormQuery,
    '&' => Expression::FormQueryContinuation
  }
  
  # This error is raised when an invalid pattern was given.
  class Invalid < StandardError
    
    include URITemplate::Invalid
  
    attr_reader :pattern, :position
    
    def initialize(source, position)
      @pattern = pattern
      @position = position
      super("Invalid expression found in #{source.inspect} at #{position}: '#{source[position..-1]}'")
    end
    
  end
  
  # @private
  class Tokenizer
  
    include Enumerable
    
    attr_reader :source
    
    def initialize(source)
      @source = source
    end
  
    def each
      if !block_given?
        return Enumerator.new(self)
      end
      scanner = StringScanner.new(@source)
      until scanner.eos?
        expression = scanner.scan(EXPRESSION)
        if expression
          vars = scanner[5].split(',').map{|name|
            match = VAR.match(name)
            [ match['varname'], match['explode'] == '*', match['length'].to_i ]
          }
          yield OPERATORS[scanner[1]].new(vars)
        else
          literal = scanner.scan(LITERAL)
          if literal
            yield(Literal.new(literal))
          else
            raise Invalid.new(@source,scanner.pos)
          end
        end
      end
    end
  
  end
  
  # The class methods for all draft7 templates.
  module ClassMethods
  
    # Tries to convert the given param in to a instance of {Draft7}
    # It basically passes thru instances of that class, parses strings and return nil on everything else.
    #
    # @example
    #   URITemplate::Draft7.try_convert( Object.new ) #=> nil
    #   tpl = URITemplate::Draft7.new('{foo}')
    #   URITemplate::Draft7.try_convert( tpl ) #=> tpl
    #   URITemplate::Draft7.try_convert('{foo}') #=> tpl
    #   # This pattern is invalid, so it wont be parsed:
    #   URITemplate::Draft7.try_convert('{foo') #=> nil
    #
    def try_convert(x)
      if x.kind_of? self
        return x
      elsif x.kind_of? String and valid? x
        return new(x)
      else
        return nil
      end
    end
    
    
    # Like {.try_convert}, but raises an ArgumentError, when the conversion failed.
    # 
    # @raise ArgumentError
    def convert(x)
      o = self.try_convert(x)
      if o.nil?
        raise ArgumentError, "Expected to receive something that can be converted to an #{self.class}, but got: #{x.inspect}."
      else
        return o
      end
    end
    
    # Tests whether a given pattern is a valid template pattern.
    # @example
    #   URITemplate::Draft7.valid? 'foo' #=> true
    #   URITemplate::Draft7.valid? '{foo}' #=> true
    #   URITemplate::Draft7.valid? '{foo' #=> false
    def valid?(pattern)
      URI === pattern
    end
  
  end
  
  extend ClassMethods
  
  attr_reader :pattern
  
  attr_reader :options
  
  # @param String,Array either a pattern as String or an Array of tokens
  # @param Hash some options
  # @option :lazy If true the pattern will be parsed on first access, this also means that syntax errors will not be detected unless accessed.
  def initialize(pattern_or_tokens,options={})
    @options = options.dup.freeze
    if pattern_or_tokens.kind_of? String
      @pattern = pattern_or_tokens.dup
      @pattern.freeze
      unless @options[:lazy]
        self.tokens
      end
    elsif pattern_or_tokens.kind_of? Array
      @tokens = pattern_or_tokens.dup
      @tokens.freeze
    else
      raise ArgumentError, "Expected to receive a pattern string, but got #{pattern_or_tokens.inspect}"
    end
  end
  
  # Expands the template with the given variables.
  # The expansion should be compatible to uritemplate spec draft 7 ( http://tools.ietf.org/html/draft-gregorio-uritemplate-07 ).
  # @note
  #   All keys of the supplied hash should be strings as anything else won't be recognised.
  # @note
  #   There are neither default values for variables nor will anything be raised if a variable is missing. Please read the spec if you want to know how undefined variables are handled.
  # @example
  #   URITemplate::Draft7.new('{foo}').expand('foo'=>'bar') #=> 'bar'
  #   URITemplate::Draft7.new('{?args*}').expand('args'=>{'key'=>'value'}) #=> '?key=value'
  #   URITemplate::Draft7.new('{undef}').expand() #=> ''
  #
  # @param variables Hash
  # @return String
  def expand(variables = {})
    tokens.map{|part|
      part.expand(variables, {})
    }.join
  end
  
  # Returns an array containing all variables. Repeated variables are ignored, but the order will be kept intact.
  # @example
  #   URITemplate::Draft7.new('{foo}{bar}{baz}').variables #=> ['foo','bar','baz']
  #   URITemplate::Draft7.new('{a}{c}{a}{b}').variables #=> ['c','a','b']
  #
  # @return Array
  def variables
    @variables ||= begin
      vars = []
      tokens.each{|token|
        if token.respond_to? :variable_names
          vn = token.variable_names.uniq
          vars -= vn
          vars.push(*vn)
        end
      }
      vars
    end
  end
  
  # Compiles this template into a regular expression which can be used to test whether a given uri matches this template. This template is also used for {#===}.
  #
  # @example
  #   tpl = URITemplate::Draft7.new('/foo/{bar}/')
  #   regex = tpl.to_r
  #   regex === '/foo/baz/' #=> true
  #   regex === '/foz/baz/' #=> false
  # 
  # @return Regexp
  def to_r
    classes = CHARACTER_CLASSES.map{|_,v| v[:class]+"{0}\n" }
    bc = 0
    @regexp ||= Regexp.new(classes.join + '\A' + tokens.map{|part|
      r = part.to_r_source(bc)
      bc += part.size
      r
    }.join + '\z' , Regexp::EXTENDED)
  end
  
  
  # Extracts variables from a uri ( given as string ) or an instance of MatchData ( which was matched by the regexp of this template.
  # The actual result depends on the value of post_processing.
  # This argument specifies whether pair arrays should be converted to hashes.
  # 
  # @example Default Processing
  #   URITemplate::Draft7.new('{var}').extract('value') #=> {'var'=>'value'}
  #   URITemplate::Draft7.new('{&args*}').extract('&a=1&b=2') #=> {'args'=>{'a'=>'1','b'=>'2'}}
  #   URITemplate::Draft7.new('{&arg,arg}').extract('&arg=1&arg=2') #=> {'arg'=>'2'}
  #
  # @example No Processing
  #   URITemplate::Draft7.new('{var}').extract('value', URITemplate::Draft7::NO_PROCESSING) #=> [['var','value']]
  #   URITemplate::Draft7.new('{&args*}').extract('&a=1&b=2', URITemplate::Draft7::NO_PROCESSING) #=> [['args',[['a','1'],['b','2']]]]
  #   URITemplate::Draft7.new('{&arg,arg}').extract('&arg=1&arg=2', URITemplate::Draft7::NO_PROCESSING) #=> [['arg','1'],['arg','2']]
  #
  # @raise Encoding::InvalidByteSequenceError when the given uri was not properly encoded.
  # @raise Encoding::UndefinedConversionError when the given uri could not be converted to utf-8.
  # @raise Encoding::CompatibilityError when the given uri could not be converted to utf-8.
  #
  # @param [String,MatchData] Uri_or_MatchData A uri or a matchdata from which the variables should be extracted.
  # @param [Array] Processing Specifies which processing should be done.
  # 
  # @note
  #   Don't expect that an extraction can fully recover the expanded variables. Extract rather generates a variable list which should expand to the uri from which it were extracted. In general the following equation should hold true:
  #     a_tpl.expand( a_tpl.extract( an_uri ) ) == an_uri
  #
  # @example Extraction cruces
  #   two_lists = URITemplate::Draft7.new('{listA*,listB*}')
  #   uri = two_lists.expand('listA'=>[1,2],'listB'=>[3,4]) #=> "1,2,3,4"
  #   variables = two_lists.extract( uri ) #=> {'listA'=>["1","2","3","4"],'listB'=>nil}
  #   # However, like said in the note:
  #   two_lists.expand( variables ) == uri #=> true
  #
  # @note
  #   The current implementation drops duplicated variables instead of checking them.
  #   
  #   
  def extract(uri_or_match, post_processing = DEFAULT_PROCESSING )
    if uri_or_match.kind_of? String
      m = self.to_r.match(uri_or_match)
    elsif uri_or_match.kind_of?(MatchData)
      if uri_or_match.regexp != self.to_r
        raise ArgumentError, "Trying to extract variables from MatchData which was not generated by this template."
      end
      m = uri_or_match
    elsif uri_or_match.nil?
      return nil
    else
      raise ArgumentError, "Expected to receive a String or a MatchData, but got #{uri_or_match.inspect}."
    end
    if m.nil?
      return nil
    else
      result = extract_matchdata(m)
      if post_processing.include? :convert_values
        result.map!{|k,v| [k, Utils.pair_array_to_hash(v)] }
      end
      
      if post_processing.include? :convert_result
        result = Utils.pair_array_to_hash(result)
      end
      
      if block_given?
        return yield result
      end
      
      return result
    end
  end
  
  # Extracts variables without any proccessing.
  # This is equivalent to {#extract} with options {NO_PROCESSING}.
  # @see #extract
  def extract_simple(uri_or_match)
    extract( uri_or_match, NO_PROCESSING )
  end
  
  # Returns the pattern for this template.
  def pattern
    @pattern ||= tokens.map(&:to_s).join
  end
  
  alias to_s pattern
  
  # Compares two template patterns.
  def ==(tpl)
    return false if self.class != tpl.class
    return self.pattern == tpl.pattern
  end
  
  # @method ===(uri)
  # Alias for to_r.=== . Tests whether this template matches a given uri.
  # @return TrueClass, FalseClass
  def_delegators :to_r, :===
  
  # @method match(uri)
  # Alias for to_r.match . Matches this template against the given uri.
  # @yield MatchData
  # @return MatchData, Object 
  def_delegators :to_r, :match

  # The type of this template.
  #
  # @example
  #   tpl1 = URITemplate::Draft7.new('/foo')
  #   tpl2 = URITemplate.new( tpl1.pattern, tpl1.type )
  #   tpl1 == tpl2 #=> true
  #
  # @see {URITemplate#type}
  def type
    :draft7
  end
  
  # Returns the level of this template according to the draft ( http://tools.ietf.org/html/draft-gregorio-uritemplate-07#section-1.2 ). Higher level means higher complexity.
  # Basically this is defined as:
  # 
  # * Level 1: no operators, one variable per expansion, no variable modifiers
  # * Level 2: '+' and '#' operators, one variable per expansion, no variable modifiers
  # * Level 3: all operators, multiple variables per expansion, no variable modifiers
  # * Level 4: all operators, multiple variables per expansion, all variable modifiers
  #
  # @example
  #   URITemplate::Draft7.new('/foo/').level #=> 1
  #   URITemplate::Draft7.new('/foo{bar}').level #=> 1
  #   URITemplate::Draft7.new('/foo{#bar}').level #=> 2
  #   URITemplate::Draft7.new('/foo{.bar}').level #=> 3
  #   URITemplate::Draft7.new('/foo{bar,baz}').level #=> 3
  #   URITemplate::Draft7.new('/foo{bar:20}').level #=> 4
  #   URITemplate::Draft7.new('/foo{bar*}').level #=> 4
  #
  # Templates of lower levels might be convertible to other formats while templates of higher levels might be incompatible. Level 1 for example should be convertible to any other format since it just contains simple expansions.
  #
  def level
    tokens.map(&:level).max
  end
  
  # Tries to conatenate two templates, as if they were path segments.
  # Removes double slashes or insert one if they are missing.
  #
  # @example
  #   tpl = URITemplate::Draft7.new('/xy/')
  #   (tpl / '/z/' ).pattern #=> '/xy/z/'
  #   (tpl / 'z/' ).pattern #=> '/xy/z/'
  #   (tpl / '{/z}' ).pattern #=> '/xy{/z}'
  #   (tpl / 'a' / 'b' ).pattern #=> '/xy/a/b'
  #
  def /(o)
    other = self.class.convert(o)
    
    if other.absolute?
      raise ArgumentError, "Expected to receive a relative template but got an absoulte one: #{other.inspect}. If you think this is a bug, please report it."
    end
    
    if other.pattern == ''
      return self
    end
    # Merge!
    # Analyze the last token of this an the first token of the next and try to merge them
    if self.tokens.last.kind_of?(Literal)
      if self.tokens.last.string[-1] == '/' # the last token ends with an /
        if other.tokens.first.kind_of? Literal
          # both seems to be paths, merge them!
          if other.tokens.first.string[0] == '/'
            # strip one '/'
            return self.class.new( self.tokens[0..-2] + [ Literal.new(self.tokens.last.string + other.tokens.first.string[1..-1]) ] + other.tokens[1..-1] )
          else
            # no problem, but we can merge them
            return self.class.new( self.tokens[0..-2] + [ Literal.new(self.tokens.last.string + other.tokens.first.string) ] + other.tokens[1..-1] )
          end
        elsif other.tokens.first.kind_of? Expression::Path
          # this will automatically insert '/'
          # so we can strip one '/'
          return self.class.new( self.tokens[0..-2] + [ Literal.new(self.tokens.last.string[0..-2]) ] + other.tokens )
        end
      end
    end
    if other.tokens.first.kind_of?(Expression::Path) or (other.tokens.first.kind_of?(Literal) and other.tokens.first.string[0] == '/')
      return self.class.new( self.tokens + other.tokens )
    else
      return self.class.new( self.tokens + [Literal.new('/')] + other.tokens )
    end
  end
  
  
  #
  # should be relative:
  #  xxx ...
  #  {xxx}x ...
  # 
  #  should not be relative:
  #  {proto}:// ...
  #  http:// ...
  #  http{ssl}:// ...
  #
  def absolute?
    read_chars = ""
    
    tokens.each do |token|
      if token.kind_of? Expression
        if token.class::OPERATOR == ''
          read_chars << "x"
        else
          return false
        end
      elsif token.kind_of? Literal
        read_chars << token.string
      end
      if read_chars =~ /^[a-z]+:\/\//i
        return true
      elsif read_chars =~ /(?<!:|\/)\/(?!\/)/
        return false
      end
    end
    
    return false
  end
  
  # Returns the number of static characters in this template.
  # This method is useful for routing, since it's often pointful to use the url with fewer variable characters.
  # For example 'static' and 'sta{var}' both match 'static', but in most cases 'static' should be prefered over 'sta{var}' since it's more specific.
  #
  # @example
  #   URITemplate::Draft7.new('/xy/').static_characters #=> 4
  #   URITemplate::Draft7.new('{foo}').static_characters #=> 0
  #   URITemplate::Draft7.new('a{foo}b').static_characters #=> 2
  #
  # @return Numeric
  def static_characters
    @static_characters ||= tokens.select{|t| t.kind_of?(Literal) }.map{|t| t.string.size }.inject(0,:+)
  end

protected
  # @private
  def tokenize!
    Tokenizer.new(pattern).to_a
  end
  
  def tokens
    @tokens ||= tokenize!
  end
  
  # @private
  def extract_matchdata(matchdata)
    bc = 0
    vars = []
    tokens.each{|part|
      i = 0
      while i < part.size
        vars.push(*part.extract(i, matchdata["v#{bc}"]))
        bc += 1
        i += 1
      end
    }
    return vars
  end
  
end


