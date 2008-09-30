# Authorization
require File.dirname(__FILE__) + '/reader.rb'
require "set"


module Authorization
  # An exception raised if anything goes wrong in the Authorization realm
  class AuthorizationError < Exception ; end
  # NotAuthorized is raised if the current user is not allowed to perform
  # the given operation possibly on a specific object.
  class NotAuthorized < AuthorizationError ; end
  # AttributeAuthorizationError is more specific than NotAuthorized, signalling
  # that the access was denied on the grounds of attribute conditions.
  class AttributeAuthorizationError < NotAuthorized ; end
  # AuthorizationUsageError is used whenever a situation is encountered
  # in which the application misused the plugin.  That is, if, e.g.,
  # authorization rules may not be evaluated.
  class AuthorizationUsageError < AuthorizationError ; end
  
  AUTH_DSL_FILE = "#{RAILS_ROOT}/config/authorization_rules.rb"
  
  # Controller-independent method for retrieving the current user.
  # Needed for model security where the current controller is not available.
  def self.current_user
    $current_user || GuestUser.new
  end
  
  # Controller-independent method for setting the current user.
  def self.current_user=(user)
    $current_user = user
  end
  
  @@ignore_access_control = false
  # For use in test cases only
  def self.ignore_access_control (state = nil) # :nodoc:
    @@ignore_access_control = state unless state.nil?
    ENV['RAILS_ENV'] == 'test' and @@ignore_access_control
  end
  
  # Authorization::Engine implements the reference monitor.  It may be used
  # for querying the permission and retrieving obligations under which
  # a certain privilege is granted for the current user.
  #
  class Engine
    attr_reader :roles
    
    # If +reader+ is not given, a new one is created with the default
    # authorization configuration of +AUTH_DSL_FILE+.  If given, may be either
    # a Reader object or a path to a configuration file.
    def initialize (reader = nil)
      if reader.nil?
        begin
          reader = Reader::DSLReader.load(AUTH_DSL_FILE)
        rescue SystemCallError
          reader = Reader::DSLReader.new
        end
      elsif reader.is_a?(String)
        reader = Reader::DSLReader.load(reader)
      end
      @privileges = reader.privileges_reader.privileges
      # {priv => [[priv, ctx],...]}
      @privilege_hierarchy = reader.privileges_reader.privilege_hierarchy
      @auth_rules = reader.auth_rules_reader.auth_rules
      @roles = reader.auth_rules_reader.roles
      @role_hierarchy = reader.auth_rules_reader.role_hierarchy
      
      # {[priv, ctx] => [priv, ...]}
      @rev_priv_hierarchy = {}
      @privilege_hierarchy.each do |key, value|
        value.each do |val| 
          @rev_priv_hierarchy[val] ||= []
          @rev_priv_hierarchy[val] << key
        end
      end
    end
    
    # Returns true if privilege is met by the current user.  Raises
    # AuthorizationError otherwise.  +privilege+ may be given with or
    # without context.  In the latter case, the :+context+ option is
    # required.
    #  
    # Options:
    # [:+context+]
    #   The context part of the privilege.
    #   Defaults either to the +table_name+ of the given :+object+, if given.
    #   That is, either :+users+ for :+object+ of type User.  
    #   Raises AuthorizationUsageError if
    #   context is missing and not to be infered.
    # [:+object+] An context object to test attribute checks against.
    # [:+skip_attribute_test+]
    #   Skips those attribute checks in the 
    #   authorization rules. Defaults to false.
    # [:+user+] 
    #   The user to check the authorization for.
    #   Defaults to Authorization#current_user.
    #
    def permit! (privilege, options = {})
      return true if Authorization.ignore_access_control
      options = {
        :object => nil,
        :skip_attribute_test => false,
        :context => nil
      }.merge(options)
      options[:context] ||= options[:object] && options[:object].class.table_name.to_sym rescue NoMethodError
      
      user, roles, privileges = user_roles_privleges_from_options(privilege, options)

      # find a authorization rule that matches for at least one of the roles and 
      # at least one of the given privileges
      attr_validator = AttributeValidator.new(user, options[:object])
      #puts "All rules: #{@auth_rules.inspect}"
      #rules_matching_roles = @auth_rules.select {|r| roles.include?(r.role) }
      #puts "Matching for roles: #{rules_matching_roles.inspect}"
      #puts "Matching rules for user   #{user.inspect},"
      #puts "                   roles  #{roles.inspect},"
      #puts "                   privs  #{privileges.inspect}:"
      #puts "   #{matching_auth_rules(roles, privileges).inspect}"
      rules = matching_auth_rules(roles, privileges, options[:context])
      if rules.empty?
        raise NotAuthorized, "No matching rules found for #{privilege} for #{user.inspect} " +
          "(roles #{roles.inspect}, privileges #{privileges.inspect}, " +
          "context #{options[:context].inspect})."
      end
      
      grant_permission = rules.any? do |rule|
        options[:skip_attribute_test] or
          rule.attributes.empty? or
          rule.attributes.any? {|attr| attr.validate? attr_validator }
      end
      unless grant_permission
        raise AttributeAuthorizationError, "#{privilege} not allowed for #{user.inspect} on #{options[:object].inspect}."
      end
      true
    end
    
    # Calls permit! but rescues the AuthorizationException and returns false
    # instead.  If no exception is raised, permit? returns true and yields
    # to the optional block.
    def permit? (privilege, options = {}, &block) # :yields:
      permit!(privilege, options)
      yield if block_given?
      true
    rescue NotAuthorized
      false
    end
    
    # Returns the obligations to be met by the current user for the given 
    # privilege as an array of obligation hashes in form of 
    #   [{:object_attribute => obligation_value, ...}, ...]
    # where +obligation_value+ is either (recursively) another obligation hash
    # or a value spec, such as
    #   [operator, literal_value]
    # The obligation hashes in the array should be OR'ed, conditions inside
    # the hashes AND'ed.
    # 
    # Example
    #   {:branch => {:company => [:is, 24]}, :active => [:is, true]}
    # 
    # Options
    # [:+context+]  See permit!
    # [:+user+]  See permit!
    # 
    def obligations (privilege, options = {})
      options = {:context => nil}.merge(options)
      user, roles, privileges = user_roles_privleges_from_options(privilege, options)
      attr_validator = AttributeValidator.new(user)
      matching_auth_rules(roles, privileges, options[:context]).collect do |rule|
        obligation = rule.attributes.collect {|attr| attr.obligation(attr_validator) }
        obligation.empty? ? [{}] : obligation
      end.flatten
    end
    
    # Returns an instance of Engine, which is created if there isn't one
    # yet.  If +dsl_file+ is given, it is passed on to Engine.new and 
    # a new instance is always created.
    def self.instance (dsl_file = nil)
      if dsl_file or ENV['RAILS_ENV'] == 'development'
        @@instance = new(dsl_file)
      else
        @@instance ||= new
      end
    end
    
    class AttributeValidator # :nodoc:
      attr_reader :user, :object
      def initialize (user, object = nil)
        @user = user
        @object = object
      end
      
      def evaluate (value_block)
        # TODO cache?
        instance_eval(&value_block)
      end
    end
    
    private
    def user_roles_privleges_from_options(privilege, options)
      options = {
        :user => nil,
        :context => nil
      }.merge(options)
      user = options[:user] || Authorization.current_user
      privileges = privilege.is_a?(Array) ? privilege : [privilege]
      
      raise AuthorizationUsageError, "No user object available (#{user.inspect})" \
        unless user
      raise AuthorizationUsageError, "User object doesn't respond to roles" \
        unless user.respond_to?(:roles)
      raise AuthorizationUsageError, "User.roles doesn't return an Array of Symbols" \
        unless user.roles.empty? or user.roles[0].is_a?(Symbol)
      
      roles = flatten_roles((user.roles.blank? ? [:guest] : user.roles))
      privileges = flatten_privileges privileges, options[:context]
      [user, roles, privileges]
    end
    
    def flatten_roles (roles)
      # TODO caching?
      flattened_roles = roles.clone.to_a
      flattened_roles.each do |role|
        flattened_roles.concat(@role_hierarchy[role]).uniq! if @role_hierarchy[role]
      end
    end
    
    # Returns the privilege hierarchy flattened for given privileges in context.
    def flatten_privileges (privileges, context = nil)
      # TODO caching?
      #if context.nil?
      #  context = privileges.collect { |p| p.to_s.split('_') }.
      #                       reject { |p_p| p_p.length < 2 }.
      #                       collect { |p_p| (p_p[1..-1] * '_').to_sym }.first
      #  raise AuthorizationUsageError, "No context given or inferable from privileges #{privileges.inspect}" unless context
      #end
      raise AuthorizationUsageError, "No context given or inferable from object" unless context
      #context_regex = Regexp.new "_#{context}$"
      # TODO work with contextless privileges
      #flattened_privileges = privileges.collect {|p| p.to_s.sub(context_regex, '')}
      flattened_privileges = privileges.clone #collect {|p| p.to_s.end_with?(context.to_s) ?
                                              #       p : [p, "#{p}_#{context}".to_sym] }.flatten
      flattened_privileges.each do |priv|
        flattened_privileges.concat(@rev_priv_hierarchy[[priv, nil]]).uniq! if @rev_priv_hierarchy[[priv, nil]]
        flattened_privileges.concat(@rev_priv_hierarchy[[priv, context]]).uniq! if @rev_priv_hierarchy[[priv, context]]
      end
    end
    
    def matching_auth_rules (roles, privileges, context)
      @auth_rules.select {|rule| rule.matches? roles, privileges, context}
    end
  end
  
  class AuthorizationRule
    attr_reader :attributes, :contexts, :role, :privileges
    
    def initialize (role, privileges = [], contexts = nil)
      @role = role
      @privileges = Set.new(privileges)
      @contexts = Set.new((contexts && !contexts.is_a?(Array) ? [contexts] : contexts))
      @attributes = []
    end
    
    def append_privileges (privs)
      @privileges.merge(privs)
    end
    
    def append_attribute (attribute)
      @attributes << attribute
    end
    
    def matches? (roles, privs, context = nil)
      roles = [roles] unless roles.is_a?(Array)
      @contexts.include?(context) and roles.include?(@role) and 
        not (@privileges & privs).empty?
    end
  end
  
  class Attribute
    # attr_conditions_hash of form
    # { :object_attribute => [operator, value_block], ... }
    # { :object_attribute => { :attr => ... } }
    def initialize (conditions_hash)
      @conditions_hash = conditions_hash
    end
    
    def validate? (attr_validator, object = nil, hash = nil)
      object ||= attr_validator.object
      return false unless object
      
      (hash || @conditions_hash).all? do |attr, value|
        begin
          attr_value = object.send(attr)
        rescue ArgumentError, NoMethodError => e
          raise AuthorizationUsageError, "Error when calling #{attr} on " +
           "#{object.inspect} for validating attribute: #{e}"
        end
        if value.is_a?(Hash)
          validate?(attr_validator, attr_value, value)
        elsif value.is_a?(Array) and value.length == 2
          evaluated = attr_validator.evaluate(value[1])
          case value[0]
          when :is
            attr_value == evaluated
          when :contains
            attr_value.include?(evaluated)
          else
            raise AuthorizationError, "Unknown operator #{value[0]}"
          end
        else
          raise AuthorizationError, "Wrong conditions hash format"
        end
      end
    end
    
    # resolves all the values in condition_hash
    def obligation (attr_validator, hash = nil)
      hash = (hash || @conditions_hash).clone
      hash.each do |attr, value|
        if value.is_a?(Hash)
          hash[attr] = obligation(attr_validator, value)
        elsif value.is_a?(Array) and value.length == 2
          hash[attr] = [value[0], attr_validator.evaluate(value[1])]
        else
          raise AuthorizationError, "Wrong conditions hash format"
        end
      end
      hash
    end
  end
  
  # Represents a pseudo-user to facilitate guest users in applications
  class GuestUser
    attr_reader :roles
    def initialize (roles = [:guest])
      @roles = roles
    end
  end
end
