require 'chrono_model/version'

require 'active_record'
require 'active_record/connection_adapters/postgresql_adapter'

module ChronoModel
  module SchemaStatements
    AR = ActiveRecord::Base

    # Creates the given table, possibly creating the temporal schema
    # objects if the `:temporal` option is given and set to true.
    #
    def create_table(table_name, options = {})
      # No temporal features requested, skip
      return super unless options[:temporal]

      if options[:id] == false
        raise AR::ActiveRecordError, "Temporal tables require a primary key."
      end

      # Create required schemas
      chrono_create_temporal_schemas!

      # Create the current table in the temporal schema
      current = chrono_current_table_for(table_name)
      super current, options

      primary_key = primary_key(current)

      chrono_create_history_for(table_name, primary_key)
      chrono_create_view_for(table_name, primary_key)
    end

    private
      def chrono_create_temporal_schemas!
        [chrono_current_schema, chrono_history_schema].each do |schema|
          execute "CREATE SCHEMA #{schema}" unless schema_exists?(schema)
        end
      end

      # Create the history table in the history schema
      def chrono_create_history_for(table, pk)
        execute <<-SQL
          CREATE TABLE #{chrono_history_table_for(table)} (
            hid         serial primary key,
            valid_from  timestamp not null,
            valid_to    timestamp not null default '9999-12-31',
            recorded_at timestamp not null default now(),

            constraint from_before_to check (valid_from < valid_to),

            constraint overlapping_times exclude using gist (
              box(
                point( extract( epoch from valid_from), id ),
                point( extract( epoch from valid_to - interval '1 millisecond'), id )
              ) with &&
            )
          ) inherits ( #{chrono_current_table_for(table)} )
        SQL

        # Create index for history timestamps
        execute <<-SQL
          CREATE INDEX timestamps ON #{chrono_history_table_for(table)}
          USING btree ( valid_from, valid_to ) WITH ( fillfactor = 100 )
        SQL

        # Create index for the inherited table primary key
        execute <<-SQL
          CREATE INDEX #{table}_pk ON #{chrono_history_table_for(table)}
          USING btree ( #{pk} ) WITH ( fillfactor = 90 )
        SQL
      end

      # Create the public view and its rules
      def chrono_create_view_for(table, pk)
        view    = chrono_view_for(table)
        current = chrono_current_table_for(table)
        history = chrono_history_table_for(table)

        # SELECT - return only current data
        #
        execute "CREATE OR REPLACE VIEW #{view} AS SELECT * FROM ONLY #{current}"

        columns  = columns(table).map(&:name)
        sequence = serial_sequence(chrono_current_table_for(table), pk) # For INSERT
        updates  = columns.map {|c| "#{c} = new.#{c}"}.join(",\n")      # For UPDATE

        columns.delete(pk)

        fields, values = columns.join(', '), columns.map {|c| "new.#{c}"}.join(', ')

        # INSERT - inert data both in the current table and in the history one
        #
        execute <<-SQL
          CREATE OR REPLACE RULE #{table}_ins AS ON INSERT TO #{view} DO INSTEAD (

            INSERT INTO #{current} ( #{fields} ) VALUES ( #{values} )
            RETURNING #{current}.*;

            INSERT INTO #{history} ( #{pk}, #{fields}, valid_from )
            VALUES ( currval('#{sequence}'), #{values}, now() )
          )
        SQL

        # UPDATE - set the last history entry validity to now, save the current data
        # in a new history entry and update the current table with the new data.
        #
        execute <<-SQL
          CREATE OR REPLACE RULE #{table}_upd AS ON UPDATE TO #{view} DO INSTEAD (

            UPDATE #{history} SET valid_to = now()
            WHERE #{pk} = old.#{pk} AND valid_to = '9999-12-31';

            INSERT INTO #{history} ( #{pk}, #{fields}, valid_from )
            VALUES ( old.#{pk}, #{values}, now() );

            UPDATE ONLY #{current} SET #{updates}
            WHERE #{pk} = old.#{pk}
          )
        SQL

        # DELETE - save the current data in the history and eventually delete the data
        # from the current table.
        execute <<-SQL
          CREATE OR REPLACE RULE #{table}_del AS ON DELETE TO #{view} DO INSTEAD (

            UPDATE #{history} SET valid_to = now()
            WHERE #{pk} = old.#{pk} AND valid_to = '9999-12-31';

            DELETE FROM ONLY #{current}
            WHERE #{current}.#{pk} = old.#{pk}
          )
        SQL
      end

      def chrono_current_schema
        'temporal'
      end

      def chrono_history_schema
        'history'
      end

      def chrono_current_table_for(table)
        [chrono_current_schema, table].join '.'
      end

      def chrono_history_table_for(table)
        [chrono_history_schema, table].join '.'
      end

      def chrono_view_for(table)
        "public.#{table}"
      end

  end
end

# Patch AR
ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.instance_eval do
  include ChronoModel::SchemaStatements
end
