module ChronoModel

  module Conversions
    extend self

    ISO_DATETIME = /\A(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)(\.\d+)?\z/

    def string_to_utc_time(string)
      if string =~ ISO_DATETIME
        microsec = ($7.to_f * 1_000_000).to_i
        Time.utc $1.to_i, $2.to_i, $3.to_i, $4.to_i, $5.to_i, $6.to_i, microsec
      end
    end

    def time_to_utc_string(time)
      [time.to_s(:db), sprintf('%06d', time.usec)].join '.'
    end
  end

  module Utilities
    # Amends the given history item setting a different period.
    # Useful when migrating from legacy systems, but it is here
    # as this is not a proper API.
    #
    # Extend your model with the Utilities model if you want to
    # use it.
    #
    def amend_period!(hid, from, to)
      unless [from, to].all? {|ts| ts.respond_to?(:zone) && ts.zone == 'UTC'}
        raise 'Can amend history only with UTC timestamps'
      end

      connection.execute %[
        UPDATE #{quoted_table_name}
           SET "valid_from" = #{connection.quote(from)},
               "valid_to"   = #{connection.quote(to  )}
         WHERE "hid" = #{hid.to_i}
      ]
    end
  end

end
