module SingleWriteMultiRead
  
  #This Module extends active record
  module ArExtensions
    #Call this method to make the model use a single write database with multiple read dbs
    def single_write_multi_read
      include SingleWriteMultiRead::InstanceMethods
      return true unless DbDefs.has_slaves?
      alias_method_chain :save, :slave
      alias_method_chain :save!, :slave
      alias_method_chain :destroy, :slave
      #alias_method_chain :class, :slave
      class << self
        #This overwrites the calculate method, to distribute calculations across DBs
        def calculate_with_slave(operation, column_name, options = {})
          DbDefs.slave_for_class(self).constantize.calculate_without_slave(operation, column_name, options)
        end
        #Overwrites the count by sql method to use a slave
        def count_by_sql_with_slave(sql)
          DbDefs.slave_for_class(self).constantize.count_by_sql_without_slave(sql)
        end
        #Uses a slave to find the model
        def find_with_slave(*args)
          DbDefs.slave_for_class(self).constantize.find_without_slave(*args)
        end
        #Finds by sql on the slave
        def find_by_sql_with_slave(sql)
          DbDefs.slave_for_class(self).constantize.find_by_sql_without_slave(sql)
        end
        
        #This breaks STI if not overwritten
        def descends_from_active_record_with_slave?
          klass_name = self.to_s.split("::").last
          klass = Kernel.const_get(klass_name)
          return klass.descends_from_active_record_without_slave?
        end
        alias_method_chain :descends_from_active_record?, :slave
        alias_method_chain :calculate, :slave
        alias_method_chain :count_by_sql, :slave
        alias_method_chain :find, :slave
        alias_method_chain :find_by_sql, :slave
      end
    end
  end
  
  #These need to be mixed in to the classes that want to be super cool and have slaves
  module InstanceMethods
    #Saves to the write master
    def save_with_slave(perform_validations = true)
      return save_without_slave(perform_validations) if new_record?
      return false if callback(:before_save) == false
      return false if callback(:before_update) == false
      if perform_validations
        return false unless self.valid?
      end
      if partial_updates?
        quoted_attributes = attributes_with_quotes(false, false, changed)
        changed_attributes.clear
      else
        quoted_attributes = attributes_with_quotes(false, false)
      end
      return 0 if quoted_attributes.empty?
      klass = class_with_slave
      sql = "UPDATE #{klass.quoted_table_name} SET #{quoted_comma_pair_list(klass.connection, quoted_attributes)} WHERE #{klass.connection.quote_column_name(klass.primary_key)} = #{quote_value(self.id)}"
      result = klass.connection.update(sql, "#{self.class.name} Master Update")
      callback(:after_update)
      callback(:after_save)
      result
    end
    
    #Save!, returns an error if it doesn't work
    def save_with_slave!
      save_with_slave || raise(RecordNotSaved)
    end
    
    #Destroys the object on the master and freezes the object
    def destroy_with_slave
      return false if callback(:before_destroy) == false
      unless new_record?
        klass = class_with_slave
        klass.connection.delete <<-end_sql, "#{self.real_class.name} Destroy"
            DELETE FROM #{self.real_class.quoted_table_name}
            WHERE #{connection.quote_column_name(self.class.primary_key)} = #{quoted_id}
          end_sql
      end
      result = freeze
      callback(:after_destroy)
      result
    end
    
    #Checks to see if it is the same object (actual class instead of assumed class)
    def ==(comparison_object)
      comparison_object.equal?(self) || (comparison_object.instance_of?(class_with_slave) && comparison_object.id == id && !comparison_object.new_record?)
    end
    
    #Returns the base class name (without the module) of the object
    def class_with_slave
      klass_name = self.class.to_s.split("::").last
      return eval(klass_name)
    end
    
    def real_class
      return self.class unless DbDefs.has_slaves?
      return class_with_slave
    end
    
    def instance_of?(klass)
      klass == self.real_class
    end
  end
end

ActiveRecord::Base.extend SingleWriteMultiRead::ArExtensions