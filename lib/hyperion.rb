require 'active_support'
require 'yaml'
require 'redis'

# TODO: splat this
require 'hyperion/base'
require 'hyperion/indices'
require 'hyperion/keys'
require 'hyperion/logger'
require 'hyperion/version'

class Hyperion
	extend Indices
	extend Keys
	extend Version
	extend Logger
	
  DEBUG = false
  # TODO: ActiveModel lint it _mayhaps_
  # TODO: atomic operations
  # TODO: default key called #{class}_id if there isn't any @@redis_key

  def initialize(opts = {})
    defaults = (self.class.class_variable_defined?('@@redis_defaults') ? self.class.class_variable_get('@@redis_defaults') : {})

    defaults.merge(opts).each {|k,v|
      self.send(k.to_s+'=',v)
    }
  end

	def self.first(conds)
		# FIXME: gotta be a faster way ;)
		self.find(conds).first
	end

  def self.find(conds)
    Hyperion.logger.debug("[RS] Searching for #{conds.inspect}") if Hyperion::DEBUG
    
    if conds.is_a? Hash then
      Hyperion.logger.debug("[RS] Its a Hash, digging through indexes!") if Hyperion::DEBUG
      ids = []
      index_keys = []
      index_values = []
      
      if conds.keys.size > 1 then
        conds.sort.each {|k,v|
          index_values << v
          index_keys << k.to_s
        }
        index_key = self.to_s.downcase + '_' + index_keys.join('.') + '_' + index_values.join('.')
        ids << Hyperion.redis.smembers(index_key)
      else
        conds.each{|k,v|
          index_key = self.to_s.downcase + '_' + k.to_s + '_' + v.to_s
          ids << Hyperion.redis.smembers(index_key)
        }
      end
      ids.flatten.uniq.collect{|i|
        self.find(i)
      }
    else
      Hyperion.logger.debug("[RS] Fetching #{self.to_s.downcase + '_' + conds.to_s}") if Hyperion::DEBUG
      v = redis[self.to_s.downcase + '_' + conds.to_s].to_s
      if v and not v.empty? then
        self.deserialize(v)
      else
        nil
      end
    end
  end

  def self.deserialize(what); YAML.load(what); end
  def serialize; YAML::dump(self); end

  def save
    Hyperion.logger.debug("[RS] Saving a #{self.class.to_s}:") if Hyperion::DEBUG
		
		unless (self.class.class_variable_defined?('@@redis_key')) then
			self.class.send('attr_accessor', 'id')
	    self.class.class_variable_set('@@redis_key', 'id')
		end
		
		unless (self.send(self.class.class_variable_get('@@redis_key'))) then
      Hyperion.logger.debug("[RS] Generating new key!") if Hyperion::DEBUG
      self.send(self.class.class_variable_get('@@redis_key').to_s + '=', new_key)
    end    

    Hyperion.logger.debug("[RS] Saving into #{full_key}: #{self.inspect}") if Hyperion::DEBUG
    Hyperion.redis[full_key] = self.serialize
    
    # Now lets update any indexes
    # BUG: need to clear out any old indexes of us
    self.class.class_variable_get('@@redis_indexes').each{|idx|
      Hyperion.logger.debug("[RS] Updating index for #{idx}") if Hyperion::DEBUG
    
      if idx.is_a?(Array) then
        index_values = idx.sort.collect {|i| self.send(i) }.join('.')
        index_key = self.class.to_s.downcase + '_' + idx.sort.join('.').to_s + '_' + index_values
      else
				value = self.send(idx)
        index_key = self.class.to_s.downcase + '_' + idx.to_s + '_' + value.to_s if value
      end
     Hyperion.logger.debug("[RS] Saving index #{index_key}: #{self.send(self.class.class_variable_get('@@redis_key'))}") if Hyperion::DEBUG
      Hyperion.redis.sadd(index_key, self.send(self.class.class_variable_get('@@redis_key')))
    } if self.class.class_variable_defined?('@@redis_indexes')
  end
  
  def self.dump(output = STDOUT, lock = false)
    # TODO: lockability and progress
    output.write(<<-eos)
# Hyperion Dump
# Generated by @adrianpike's Hyperion gem.
    eos
    output.write('# Generated on ' + Time.current.to_s + "\n")
    output.write('# DB size is ' + redis.dbsize.to_s + "\n")
    
    redis.keys.each{|k|
      case redis.type(k)
      when "string"
        output.write({ k => redis.get(k)}.to_yaml)
      when "set"
        output.write({ k => redis.smembers(k) }.to_yaml)
      end
    }
  end
  

  # THIS SHIT IS MAD DANGEROUS, BEWARE DATA INTEGRITY
  def self.load(file = STDIN, truncate = true, lock = false)
    # TODO: lockability and progress    
    
    YAML.each_document( file ) do |ydoc|
      ydoc.each {|k,v|
        redis.del(k) if truncate

        case v.class.to_s
          when 'String'
            redis[k] = v
          when 'Array'
            v.each{|val|
              redis.sadd(k,val)
            }
          else
            p v.class
        end
      }
    end
    
  end
  
  # THIS SHIT IS MAD DANGEROUS, BEWARE DATA INTEGRITY
  def self.truncate!
    redis.flushdb
  end
  
  private
    def new_key
      if (self.class.class_variable_defined?('@@redis_generate_key') and self.class.class_variable_get('@@redis_generate_key') == false)
        raise NoKey
      else
        Hyperion.redis.incr(self.class.to_s.downcase + '_' + self.class.class_variable_get('@@redis_key').to_s)
      end
    end
    
    def full_key
      self.class.to_s.downcase + '_' + self.send(self.class.class_variable_get('@@redis_key')).to_s
    end
end