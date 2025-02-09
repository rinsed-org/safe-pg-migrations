# frozen_string_literal: true

module SafePgMigrations
  module StatementInsurer # rubocop:disable Metrics/ModuleLength
    PG_11_VERSION_NUM = 110_000

    %i[change_column_null change_column].each do |method|
      define_method method do |*args, &block|
        with_setting(:statement_timeout, SafePgMigrations.config.pg_safe_timeout) { super(*args, &block) }
      end
      ruby2_keywords method
    end

    ruby2_keywords def add_column(table_name, column_name, type, *args) # rubocop:disable Metrics/CyclomaticComplexity
      options = args.last.is_a?(Hash) ? args.last : {}
      return super if SafePgMigrations.pg_version_num >= PG_11_VERSION_NUM

      default = options.delete(:default)
      null = options.delete(:null)

      if !default.nil? || null == false
        SafePgMigrations.say_method_call(:add_column, table_name, column_name, type, options)
      end

      super

      unless default.nil?
        SafePgMigrations.say_method_call(:change_column_default, table_name, column_name, default)
        change_column_default(table_name, column_name, default)

        SafePgMigrations.say_method_call(:backfill_column_default, table_name, column_name)
        backfill_column_default(table_name, column_name)
      end

      if null == false # rubocop:disable Style/GuardClause
        SafePgMigrations.say_method_call(:change_column_null, table_name, column_name, null)
        change_column_null(table_name, column_name, null)
      end
    end

    ruby2_keywords def add_foreign_key(from_table, to_table, *args)
      options = args.last.is_a?(Hash) ? args.last : {}
      validate_present = options.key? :validate
      options[:validate] = false unless validate_present
      with_setting(:statement_timeout, SafePgMigrations.config.pg_safe_timeout) do
        super(from_table, to_table, **options)
      end

      return if validate_present

      suboptions = options.slice(:name, :column)
      without_statement_timeout { validate_foreign_key from_table, suboptions.present? ? nil : to_table, **suboptions }
    end

    ruby2_keywords def create_table(*)
      with_setting(:statement_timeout, SafePgMigrations.config.pg_safe_timeout) do
        super do |td|
          yield td if block_given?
          td.indexes.map! do |key, index_options|
            index_options[:algorithm] ||= :default
            [key, index_options]
          end
        end
      end
    end

    def add_index(table_name, column_name, **options)
      if options[:algorithm] == :default
        options.delete :algorithm
      else
        options[:algorithm] = :concurrently
      end

      SafePgMigrations.say_method_call(:add_index, table_name, column_name, **options)

      without_timeout { super(table_name, column_name, **options) }
    end

    # Rails >= 6.1 signature: remove_index(table_name, column_name = nil, **options)
    # Rails <  6.1 signature: remove_index(table_name, options = {})
    # NOTE: This currently only supports Rails >= 6.1
    def remove_index(table_name, column_name = nil, **options)
      options[:algorithm] = :concurrently unless options.key?(:algorithm)

      SafePgMigrations.say_method_call(:remove_index, table_name, column_name, **options)

      without_timeout { super(table_name, column_name, **options) }
    end

    def backfill_column_default(table_name, column_name)
      quoted_table_name = quote_table_name(table_name)
      quoted_column_name = quote_column_name(column_name)
      primary_key_offset = 0
      loop do
        ids = query_values <<~SQL.squish
          SELECT id FROM #{quoted_table_name} WHERE id > #{primary_key_offset}
          ORDER BY id LIMIT #{SafePgMigrations.config.batch_size}
        SQL
        break if ids.empty?

        primary_key_offset = ids.last
        execute <<~SQL.squish
          UPDATE #{quoted_table_name} SET #{quoted_column_name} = DEFAULT WHERE id IN (#{ids.join(',')})
        SQL
      end
    end

    def with_setting(key, value)
      old_value = query_value("SHOW #{key}")
      execute("SET #{key} TO #{quote(value)}")
      begin
        yield
      ensure
        begin
          execute("SET #{key} TO #{quote(old_value)}")
        rescue ActiveRecord::StatementInvalid => e
          # Swallow `PG::InFailedSqlTransaction` exceptions so as to keep the
          # original exception (if any).
          raise unless e.cause.is_a?(PG::InFailedSqlTransaction)
        end
      end
    end

    def without_statement_timeout
      with_setting(:statement_timeout, 0) { yield }
    end

    def without_lock_timeout
      with_setting(:lock_timeout, 0) { yield }
    end

    def without_timeout
      without_statement_timeout { without_lock_timeout { yield } }
    end
  end
end
