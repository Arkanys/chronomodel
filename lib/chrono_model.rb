require 'chrono_model/version'
require 'chrono_model/adapter'

module ChronoModel
  class Error < ActiveRecord::ActiveRecordError #:nodoc:
  end
end

# Replace AR's PG adapter with the ChronoModel one. This (dirty) approach is
# required because the PG adapter defines +add_column+ itself, thus making
# impossible to use super() in overridden Module methods.
#
silence_warnings do
  ActiveRecord::ConnectionAdapters.const_set :PostgreSQLAdapter, ChronoModel::Adapter
end
