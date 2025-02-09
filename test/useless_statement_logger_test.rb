# frozen_string_literal: true

require 'test_helper'

class UselessStatementLoggerTest < MiniTest::Test
  def setup
    SafePgMigrations.instance_variable_set(:@config, nil)
    @connection = ActiveRecord::Base.connection
    @verbose_was = ActiveRecord::Migration.verbose
    @connection.create_table(:schema_migrations) { |t| t.string :version }
    ActiveRecord::SchemaMigration.create_table
    ActiveRecord::Migration.verbose = false
    @connection.execute("SET statement_timeout TO '70s'")
    @connection.execute("SET lock_timeout TO '70s'")
  end

  def teardown
    ActiveRecord::SchemaMigration.drop_table
    @connection.execute('SET statement_timeout TO 0')
    @connection.execute("SET lock_timeout TO '30s'")
    @connection.drop_table(:messages, if_exists: true)
    @connection.drop_table(:users, if_exists: true)
    ActiveRecord::Migration.verbose = @verbose_was
  end

  def test_ddl_transactions
    @migration =
      Class.new(ActiveRecord::Migration::Current) do
        disable_ddl_transaction!

        def change
          create_table(:users) { |t| t.string :email }
        end
      end.new

    write_calls = record_calls(SafePgMigrations, :say) { run_migration }.map(&:first)

    assert_includes(
      write_calls,
      '/!\ No need to explicitly use `disable_ddl_transaction`, safe-pg-migrations does it for you'
    )
  end

  def test_no_warning_when_no_ddl_transaction
    @migration =
      Class.new(ActiveRecord::Migration::Current) do
        def change
          create_table(:users) { |t| t.string :email }
        end
      end.new

    write_calls = record_calls(SafePgMigrations, :say) { run_migration }.map(&:first)

    refute_includes write_calls, '/!\ No need to explicitly disable DDL transaction, safe-pg-migrations does it for you'
  end

  def test_add_index_concurrently
    @connection.create_table(:users) { |t| t.string :email }
    @migration =
      Class.new(ActiveRecord::Migration::Current) do
        def change
          add_index :users, :email, algorithm: :concurrently
        end
      end.new

    write_calls = record_calls(SafePgMigrations, :say) { run_migration }.map(&:first)

    assert_includes(
      write_calls,
      '/!\ No need to explicitly use `algorithm: :concurrently`, safe-pg-migrations does it for you'
    )
  end

  def test_no_warning_when_no_index_concurrently
    @connection.create_table(:users) { |t| t.string :email }
    @migration =
      Class.new(ActiveRecord::Migration::Current) do
        def change
          add_index :users, :email
        end
      end.new

    write_calls = record_calls(SafePgMigrations, :say) { run_migration }.map(&:first)

    refute_includes(
      write_calls,
      '/!\ No need to explicitly use `algorithm: :concurrently`, safe-pg-migrations does it for you'
    )
  end

  def test_add_foreign_key_validate_false
    @connection.create_table(:users) { |t| t.string :email }
    @connection.create_table(:messages) do |t|
      t.string :message
      t.bigint :user_id
    end

    @migration =
      Class.new(ActiveRecord::Migration::Current) do
        def change
          add_foreign_key :messages, :users, validate: false
        end
      end.new

    write_calls = record_calls(SafePgMigrations, :say) { run_migration }.map(&:first)

    assert_includes(
      write_calls,
      '/!\ No need to explicitly use `validate: :false`, safe-pg-migrations does it for you'
    )
  end

  def test_add_foreign_key_no_validation
    @connection.create_table(:users) { |t| t.string :email }
    @connection.create_table(:messages) do |t|
      t.string :message
      t.bigint :user_id
    end

    @migration =
      Class.new(ActiveRecord::Migration::Current) do
        def change
          add_foreign_key :messages, :users
        end
      end.new

    write_calls = record_calls(SafePgMigrations, :say) { run_migration }.map(&:first)

    refute_includes(
      write_calls,
      '/!\ No need to explicitly use `validate: :false`, safe-pg-migrations does it for you'
    )
  end
end
