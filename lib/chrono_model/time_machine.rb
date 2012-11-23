require 'active_record'

module ChronoModel

  module TimeMachine
    extend ActiveSupport::Concern

    included do
      unless supports_chrono?
        raise Error, "Your database server is not supported by ChronoModel. "\
          "Currently, only PostgreSQL >= 9.0 is supported."
      end

      if table_exists? && !chrono?
        raise Error, "#{table_name} is not a temporal table. " \
          "Please use change_table :#{table_name}, :temporal => true"
      end

      history = TimeMachine.define_history_model_for(self)
      TimeMachine.chrono_models[table_name] = history
    end

    # Returns an Hash keyed by table name of ChronoModels
    #
    def self.chrono_models
      (@chrono_models ||= {})
    end

    def self.define_history_model_for(model)
      history = Class.new(model) do
        self.table_name = [Adapter::HISTORY_SCHEMA, model.table_name].join('.')

        extend TimeMachine::HistoryMethods

        # The history id is `hid`, but this cannot set as primary key
        # or temporal assocations will break. Solutions are welcome.
        def id
          hid
        end

        # Referenced record ID
        #
        def rid
          attributes[self.class.primary_key]
        end

        # HACK to make ActiveAdmin work properly. This will be surely
        # better written in the future.
        #
        def self.find(*args)
          old = self.primary_key
          self.primary_key = :hid
          super
        ensure
          self.primary_key = old
        end

        # SCD Type 2 validity from timestamp
        #
        def valid_from
          utc_timestamp_from('valid_from')
        end

        # SCD Type 2 validity to timestamp
        #
        def valid_to
          utc_timestamp_from('valid_to')
        end

        # History recording timestamp
        #
        def recorded_at
          utc_timestamp_from('recorded_at')
        end

        # Returns the previous history entry, or nil if this
        # is the first one.
        #
        def pred
          return nil if self.valid_from.year.zero?
          self.class.where(:id => rid, :valid_to => valid_from_before_type_cast).first
        end

        # Returns the next history entry, or nil if this is the
        # last one.
        #
        def succ
          return nil if self.valid_to.year == 9999
          self.class.where(:id => rid, :valid_from => valid_to_before_type_cast).first
        end
        alias :next :succ

        # Returns the first history entry
        #
        def first
          self.class.where(:id => rid).order(:valid_from).first
        end

        # Returns the last history entry
        #
        def last
          self.class.where(:id => rid).order(:valid_from).last
        end

        # Returns this history entry's current record
        #
        def record
          self.class.superclass.find(rid)
        end

        # Virtual attribute used to pass around the
        # current timestamp in association queries
        #
        def as_of_time
          Conversions.string_to_utc_time attributes['as_of_time']
        end

        # Inhibit destroy of historical records
        #
        def destroy
          raise ActiveRecord::ReadOnlyRecord, 'Cannot delete historical records'
        end

        private
          # Hack around AR timezone support. These timestamps are recorded
          # by the chrono rewrite rules in UTC, but AR reads them as they
          # were stored in the local timezone - thus here we reset its
          # assumption. TODO: OPTIMIZE.
          #
          if ActiveRecord::Base.default_timezone != :utc
            def utc_timestamp_from(attr)
              attributes[attr].utc + Time.now.utc_offset
            end
          else
            def utc_timestamp_from(attr)
              attributes[attr]
            end
          end
      end

      model.singleton_class.instance_eval do
        define_method(:history) { history }
      end

      model.const_set :History, history

      return history
    end

    # Returns a read-only representation of this record as it was +time+ ago.
    #
    def as_of(time)
      self.class.as_of(time).where(:id => self.id).first!
    end

    # Return the complete read-only history of this instance.
    #
    def history
      self.class.history.of(self)
    end

    # Returns an Array of timestamps for which this instance has an history
    # record. Takes temporal associations into account.
    #
    def history_timestamps
      self.class.history.timestamps(self)
    end

    # Returns a boolean indicating whether this record is an history entry.
    #
    def historical?
      self.kind_of? self.class.history
    end

    # Returns the previous record in the history, or nil if this is the only
    # recorded entry.
    #
    def pred
      history.order('valid_to DESC').offset(1).first
    end

    # Returns the differences between this record and the previous history
    # entry. The representation is an hash keyed by attribute whose values
    # are arrays containing the current and previous attributevalues.
    #
    def last_changes
      internals = %W( id hid valid_from valid_to recorded_at as_of_time )

      pred = self.pred
      return unless pred

      changes = self.clone.tap do |this|
        (attribute_names - internals).each do |attr|
          this.public_send("#{attr}=", pred.public_send(attr))
        end
      end.changes

      return changes
    end

    # Wraps AR::Base#attributes by removing the __xid internal attribute
    # used to squash together changes made in the same transaction.
    #
    %w( attributes attribute_names ).each do |name|
      define_method(name) { super().tap {|x| x.delete('__xid')} }
    end

    module ClassMethods
      # Returns an ActiveRecord::Relation on the history of this model as
      # it was +time+ ago.
      def as_of(time)
        history.as_of(time, current_scope)
      end
    end

    # Methods that make up the history interface of the companion History
    # model, automatically built for each Model that includes TimeMachine
    module HistoryMethods
      # Fetches as of +time+ records.
      #
      def as_of(time, scope = nil)
        time = Conversions.time_to_utc_string(time.utc) if time.kind_of? Time

        as_of = superclass.unscoped.readonly.
          with(superclass.table_name, at(time))

        # Add default scopes back if we're passed nil or a
        # specific scope, because we're .unscopeing above.
        #
        scopes = scope.present? ? [scope] : (
          superclass.default_scopes.map do |s|
            s.respond_to?(:call) ? s.call : s
          end)

        scopes.each do |s|
          s.order_values.each {|clause| as_of = as_of.order(clause.to_sql)}
          s.where_values.each {|clause| as_of = as_of.where(clause.to_sql)}
        end

        as_of.instance_variable_set(:@temporal, time)

        return as_of
      end

      # Fetches history record at the given time
      #
      def at(time)
        from, to = quoted_history_fields
        unscoped.
          select("#{quoted_table_name}.*, '#{time}' AS as_of_time").
          where("'#{time}' >= #{from} AND '#{time}' < #{to}")
      end

      # Returns the whole history as read only.
      #
      def all
        readonly.
          order("#{quoted_table_name}.recorded_at, hid").all
      end

      # Fetches the given +object+ history, sorted by history record time
      # by default. Always includes an "as_of_time" column that is either
      # the valid_to timestamp or now() if history validity is maximum.
      #
      def of(object)
        readonly.where(:id => object).extend(HistorySelect)
      end

      module HistorySelect #:nodoc:
        Aggregates = %r{(?:(?:bit|bool)_(?:and|or)|(?:array_|string_|xml)agg|count|every|m(?:in|ax)|sum|stddev|var(?:_pop|_samp|iance)|corr|covar_|regr_)\w*\s*\(}

        def build_arel
          has_aggregate = select_values.any? do |v|
            v.kind_of?(Arel::Nodes::Function) || # FIXME this is a bit ugly.
            v.to_s =~ Aggregates
          end

          return super if has_aggregate

          if order_values.blank?
            self.order_values += ["#{quoted_table_name}.recorded_at, #{quoted_table_name}.hid"]
          end

          super.tap do |rel|
            rel.project("LEAST(valid_to, now()::timestamp) AS as_of_time")
          end
        end
      end

      include(TS = Module.new do
        # Returns an Array of unique UTC timestamps for which at least an
        # history record exists. Takes temporal associations into account.
        #
        def timestamps(record = nil)
          assocs = reflect_on_all_associations.select {|a|
            !a.options[:polymorphic] && [:belongs_to, :has_one].include?(a.macro) && a.klass.chrono?
          }

          models = []
          models.push self if self.chrono?
          models.concat(assocs.map {|a| a.klass.history})

          fields = models.inject([]) {|a,m| a.concat m.quoted_history_fields}

          relation = self.
            joins(*assocs.map(&:name)).
            select("DISTINCT UNNEST(ARRAY[#{fields.join(',')}]) AS ts").
            order('ts')

          relation = relation.from(%["public".#{quoted_table_name}]) unless self.chrono?
          relation = relation.where(:id => record) if record

          sql = "SELECT ts FROM ( #{relation.to_sql} ) foo WHERE ts IS NOT NULL AND ts < NOW()"
          sql << " AND ts >= '#{record.history.first.valid_from}'" \
            if record && record.class.chrono?

          sql.gsub! 'INNER JOIN', 'LEFT OUTER JOIN'

          connection.on_schema(Adapter::HISTORY_SCHEMA) do
            connection.select_values(sql, "#{self.name} periods").map! do |ts|
              Conversions.string_to_utc_time ts
            end
          end
        end
      end)

      def quoted_history_fields
        @quoted_history_fields ||= [:valid_from, :valid_to].map do |field|
          [connection.quote_table_name(table_name),
           connection.quote_column_name(field)
          ].join('.')
        end
      end
    end

    module QueryMethods
      def build_arel
        super.tap do |arel|

          # Extract joined tables and add temporal WITH if appropriate
          arel.join_sources.map {|j| j.to_sql =~ /JOIN "(\w+)" ON/ && $1}.compact.each do |table|
            next unless (model = TimeMachine.chrono_models[table])
            with(table, model.history.at(@temporal))
          end if @temporal

        end
      end
    end
    ActiveRecord::Relation.instance_eval { include QueryMethods }

  end

end
