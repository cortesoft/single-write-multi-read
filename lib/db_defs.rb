#This module will create the required read connections.. the primary connection will be used for all writes
require 'magic_multi_connections'
#This module limits the number of connections because MMC sucks and connects a billion times
module ConnectionLimiter
  def self.included(base)
    base.instance_eval do
      def const_missing(const_id)
        # return pre_connected_const_missing(const_id) rescue nil
        target_class = "#{self.parent_module}::#{const_id}".constantize rescue nil
        raise NameError.new("uninitialized constant \{const_id}") unless target_class
        
        # The code below is used to solve an issue with the acts_as_versioned
        # plugin.  Because the acts_as_versioned plugin creates a 'Version' model
        # in the namespace of the class itself, the mmc method const_missing() will
        # never get called.  To get around this issue I have modified the acts_as_versioned
        # plugin so that it uses the inherited() method and forces a new ActiveRecord object
        # to be created.  That inheritance method relies on mmc_owner function created below.
        mmc_owner = self
        klass = create_class const_id, target_class do
          @@mmc_owner = mmc_owner
          def self.mmc_owner
            @@mmc_owner
          end
        end
        @@conn_hash ||= {}
        if @@conn_hash[self.parent_module]
          klass.connection = @@conn_hash[self.parent_module]
        else        
          klass.establish_connection self.connection_spec
          @@conn_hash[self.parent_module] = klass.connection
        end
        DbDefs.register_connection(klass.connection, self.parent_module)
        klass
      end
    end
  end
end

module DbDefs
  #Loads the connectors and removes test, production, and development
  read_slaves = YAML.load_file("#{RAILS_ROOT}/config/database.yml").delete_if {|key, value| 
    ['production', 'development', 'test'].include?(key) or (RAILS_ENV == "test" and !key.include?("test")) or 
      (RAILS_ENV != "test" and key.include?("test_")) or (RAILS_ENV == "development" and !key.include?("development")) or !key.downcase.include?("slave")
  }
  @@slaves = Array.new
  read_slaves.keys.each do |slave|
    module_name = slave.camelcase
    slave_symbol = :"#{slave}"
    st = "module #{module_name}\nend"
    Object.module_eval(st)
    mod = eval("#{module_name}")
    RAILS_DEFAULT_LOGGER.info("Establishing connection to #{slave_symbol}")
    RAILS_DEFAULT_LOGGER.flush
    mod.send :establish_connection, slave_symbol
    #This connection limiter needs to be included because MMC is stupid
    mod.send :include, ConnectionLimiter
    @@slaves << module_name
  end
  
  def DbDefs.has_slaves?
    return @@slaves.size > 0
  end
  
  def DbDefs.register_connection(conn, p_mod)
    @@slave_connections ||= {}
    @@slave_connections[p_mod] ||= conn
  end
  
  def DbDefs.verify_connections
    @@slave_connections ||= {}
    @@slave_connections.each {|p_mod, conn|
      conn.verify!(2.minutes)
    }
  end
  
  #Returns the namespace prefix of a slave
  def DbDefs.get_slave(num = false)
    return "#{@@slaves[0]}" if @@slaves.size == 1
    return false unless @@slaves.size > 0
    num ||= rand(@@slaves.size)
    num = @@slaves.size - 1 if num >= @@slaves.size
    return "#{@@slaves[num]}"
  end
  
  #Returns a slaved version of the class passed
  def DbDefs.slave_for_class(klass, num = false)
    #First checks to see if this class is already a slave, in which case it will return itself
    klass.to_s.split("::").each {|x|
      return klass.to_s if @@slaves.include?(x)
    }
    prefix = DbDefs.get_slave(num)
    return klass unless prefix
    s = "#{prefix}::#{klass.to_s}"
    #Story.logger.info(s)
    return s
  end
end