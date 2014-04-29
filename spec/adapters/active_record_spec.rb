# Don't run these specs in JRuby until jruby-pg is compatible with ActiveRecord.
unless defined?(RUBY_ENGINE) && RUBY_ENGINE == 'jruby'

  require 'spec_helper'
  require 'active_record'

  ActiveRecord::Base.establish_connection(QUE_URL)
  Que.connection = ActiveRecord
  QUE_ADAPTERS[:active_record] = Que.adapter

  describe "Que using the ActiveRecord adapter" do
    before { Que.adapter = QUE_ADAPTERS[:active_record] }

    it_behaves_like "a multi-threaded Que adapter"

    it "should use the same connection that ActiveRecord does" do
      begin
        class ActiveRecordJob < Que::Job
          def run
            $pid1 = Integer(Que.execute("select pg_backend_pid()").first['pg_backend_pid'])
            $pid2 = Integer(ActiveRecord::Base.connection.select_value("select pg_backend_pid()"))
          end
        end

        ActiveRecordJob.enqueue
        Que::Job.work

        $pid1.should == $pid2
      ensure
        $pid1 = $pid2 = nil
      end
    end

    context "if the connection goes down and is reconnected" do
      class NonsenseJob < Que::Job ; def run ; 2 + 2 end ; end
      before do
        NonsenseJob.enqueue
        ActiveRecord::Base.connection.reconnect!
      end

      it "should recreate the prepared statements" do
        expect { NonsenseJob.enqueue }.not_to raise_error
      end

      it "should log this extraordinary event" do
        NonsenseJob.enqueue
        $logger.messages.count.should == 1
        message = JSON.load($logger.messages.first)
        message['lib'].should == 'que'
        message['event'].should match %r{Re-preparing}
      end
    end

    it "should instantiate args as ActiveSupport::HashWithIndifferentAccess" do
      ArgsJob.enqueue :param => 2
      Que::Job.work
      $passed_args.first[:param].should == 2
      $passed_args.first.should be_an_instance_of ActiveSupport::HashWithIndifferentAccess
    end

    it "should support Rails' special extensions for times" do
      Que.mode = :async
      sleep_until { Que::Worker.workers.all? &:sleeping? }

      Que::Job.enqueue :run_at => 1.minute.ago
      DB[:que_jobs].get(:run_at).should be_within(3).of Time.now - 60

      Que.wake_interval = 0.005.seconds
      sleep_until { DB[:que_jobs].empty? }
    end

    it "should wake up a Worker after queueing a job in async mode, waiting for a transaction to commit if necessary" do
      Que.mode = :async
      sleep_until { Que::Worker.workers.all? &:sleeping? }

      # Wakes a worker immediately when not in a transaction.
      Que::Job.enqueue
      sleep_until { Que::Worker.workers.all?(&:sleeping?) && DB[:que_jobs].empty? }

      ActiveRecord::Base.transaction do
        Que::Job.enqueue
        Que::Worker.workers.each { |worker| worker.should be_sleeping }
      end
      sleep_until { Que::Worker.workers.all?(&:sleeping?) && DB[:que_jobs].empty? }

      # Do nothing when queueing with a specific :run_at.
      BlockJob.enqueue :run_at => Time.now
      Que::Worker.workers.each { |worker| worker.should be_sleeping }
    end

    it "should be able to tell when it's in an ActiveRecord transaction" do
      Que.adapter.should_not be_in_transaction
      ActiveRecord::Base.transaction do
        Que.adapter.should be_in_transaction
      end
    end
  end
end
