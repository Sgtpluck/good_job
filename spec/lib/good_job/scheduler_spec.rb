# frozen_string_literal: true

require 'rails_helper'

RSpec.describe GoodJob::Scheduler do
  let(:performer) { instance_double(GoodJob::JobPerformer, next: nil, name: '', next_at: [], cleanup: nil, performing_active_job_ids: Concurrent::Set.new) }

  after do
    described_class.instances.each(&:shutdown)
  end

  describe '#name' do
    it 'is human readable and contains configuration values' do
      scheduler = described_class.new(performer)
      expect(scheduler.name).to eq('GoodJob::Scheduler(queues= max_threads=5)')
    end
  end

  context 'when thread error' do
    let(:error_proc) { double("Error Collector", call: nil) } # rubocop:disable RSpec/VerifiedDoubles

    before do
      allow(GoodJob).to receive(:on_thread_error).and_return(error_proc)
      stub_const 'THREAD_HAS_RUN', Concurrent::AtomicBoolean.new(false)
      stub_const 'ERROR_TRIGGERED', Concurrent::AtomicBoolean.new(false)
    end

    context 'when on task thread' do
      it 'calls GoodJob.on_thread_error for thread errors' do
        allow(performer).to receive(:next) do
          THREAD_HAS_RUN.make_true
          raise "Whoops"
        end

        allow(error_proc).to receive(:call) do
          ERROR_TRIGGERED.make_true
        end

        scheduler = described_class.new(performer)
        scheduler.create_thread
        sleep_until { THREAD_HAS_RUN.true? }
        sleep_until { ERROR_TRIGGERED.true? }

        expect(error_proc).to have_received(:call).with(an_instance_of(RuntimeError).and(having_attributes(message: 'Whoops')))

        scheduler.shutdown
      end

      it 'calls GoodJob.on_thread_error for unhandled_errors' do
        allow(performer).to receive(:next) do
          THREAD_HAS_RUN.make_true
          GoodJob::ExecutionResult.new(value: nil, unhandled_error: StandardError.new("oopsy"))
        end

        allow(error_proc).to receive(:call) do
          ERROR_TRIGGERED.make_true
        end

        scheduler = described_class.new(performer)
        scheduler.create_thread
        sleep_until { THREAD_HAS_RUN.true? }
        sleep_until { ERROR_TRIGGERED.true? }

        expect(error_proc).to have_received(:call).with(an_instance_of(StandardError).and(having_attributes(message: 'oopsy'))).at_least(:once)
      end
    end
  end

  describe '.instances' do
    it 'contains all registered instances' do
      scheduler = nil
      expect do
        scheduler = described_class.new(performer)
      end.to change { described_class.instances.size }.by(1)

      expect(described_class.instances).to include scheduler
    end
  end

  describe '#task_observer' do
    it 'increases metric counters' do
      allow(GoodJob).to receive(:on_thread_error)

      failed_job_count = 0
      succeeded_job_count = 0

      allow(performer).to receive(:next) do
        if failed_job_count < 7
          failed_job_count += 1
          GoodJob::ExecutionResult.new(value: nil, unhandled_error: StandardError.new("oopsy"))
        elsif succeeded_job_count < 9
          succeeded_job_count += 1
          GoodJob::ExecutionResult.new(value: 'success')
        end
      end

      scheduler = described_class.new(performer)
      scheduler.create_thread
      sleep_until { scheduler.stats[:total_executions_count] == 17 }
      scheduler.shutdown

      expect(scheduler.stats).to include(
        empty_executions_count: 1,
        errored_executions_count: 7,
        succeeded_executions_count: 9,
        unexecutable_executions_count: 0,
        total_executions_count: 17
      )
    end
  end

  describe '#shutdown' do
    it 'shuts down the theadpools' do
      scheduler = described_class.new(performer)

      expect { scheduler.shutdown }
        .to change(scheduler, :running?).from(true).to(false)
    end

    context 'when threads are killed' do
      before do
        allow(performer).to receive(:performing_active_job_ids).and_return Concurrent::Set.new(%w[fake-id-1 fake-id-2])
        allow(performer).to receive(:next) { sleep 99 }
      end

      it 'kills the threadpools and logs a message with the job ids' do
        scheduler = described_class.new(performer)
        scheduler.create_thread
        sleep_until { scheduler.stats[:active_threads] > 0 }

        captured_logs = []
        allow(GoodJob::LogSubscriber.logger).to receive(:warn) { |&block| captured_logs << block.call }

        scheduler.shutdown(timeout: 0)
        expect(scheduler.shutdown?).to be true

        expect(captured_logs).to contain_exactly("GoodJob scheduler has been killed. The following Active Jobs were interrupted: fake-id-1 fake-id-2")
      end
    end
  end

  describe '#restart' do
    it 'restarts the threadpools' do
      scheduler = described_class.new(performer)
      scheduler.shutdown

      expect { scheduler.restart }
        .to change(scheduler, :running?).from(false).to(true)
    end

    it 'resets metrics' do
      allow(performer).to receive(:next).and_return GoodJob::ExecutionResult.new(value: 'hello'), nil

      scheduler = described_class.new(performer)
      scheduler.create_thread

      sleep_until do
        scheduler.stats.fetch(:succeeded_executions_count) == 1
      end

      scheduler.shutdown
      expect(scheduler.stats.fetch(:succeeded_executions_count)).to eq 1

      expect { scheduler.restart }
        .to change(scheduler, :running?).from(false).to(true)

      expect(scheduler.stats.fetch(:succeeded_executions_count)).to eq 0
    end

    it 'can be called multiple times' do
      scheduler = described_class.new(performer)
      scheduler.shutdown
      expect do
        scheduler.restart
        scheduler.restart
        scheduler.restart
      end.not_to raise_error
      scheduler.shutdown
    end
  end

  describe '#create_thread' do
    # The JRuby version of the ThreadPoolExecutor sometimes does not immediately
    # create a thread, which causes this test to flake on JRuby.
    it 'returns false if there are no threads available', :skip_if_java do
      configuration = GoodJob::Configuration.new({ queues: 'mice:1' })
      scheduler = described_class.from_configuration(configuration)

      scheduler.create_thread(queue_name: 'mice')
      expect(scheduler.create_thread(queue_name: 'mice')).to be_nil
    end

    it 'returns true if the state matches the performer' do
      configuration = GoodJob::Configuration.new({ queues: 'mice:2' })
      scheduler = described_class.from_configuration(configuration)

      expect(scheduler.create_thread(queue_name: 'mice')).to be true
    end

    it 'returns false if the state does not match the performer' do
      configuration = GoodJob::Configuration.new({ queues: 'mice:2' })
      scheduler = described_class.from_configuration(configuration)

      expect(scheduler.create_thread(queue_name: 'elephant')).to be false
    end

    it 'uses state[:count] to create multiple threads' do
      job_performer = instance_double(GoodJob::JobPerformer, next: nil, next?: true, name: '', next_at: [], cleanup: nil)
      scheduler = described_class.new(job_performer, max_threads: 1)
      allow(scheduler).to receive(:create_task)

      result = scheduler.create_thread({ count: 10 })
      expect(result).to be true
      expect(scheduler).to have_received(:create_task).exactly(10).times
    end
  end

  describe '#stats' do
    it 'contains information about the scheduler' do
      max_threads = 7
      max_cache = 13
      scheduler = described_class.new(performer, max_threads: max_threads, max_cache: max_cache)

      expect(scheduler.stats).to eq({
                                      name: scheduler.name,
                                      queues: performer.name,
                                      max_threads: max_threads,
                                      active_threads: 0,
                                      available_threads: max_threads,
                                      max_cache: max_cache,
                                      active_cache: 0,
                                      available_cache: max_cache,
                                      empty_executions_count: 0,
                                      errored_executions_count: 0,
                                      succeeded_executions_count: 0,
                                      unexecutable_executions_count: 0,
                                      total_executions_count: 0,
                                    })
    end
  end

  describe '#cleanup' do
    context 'when there are more than cleanup_interval_jobs' do
      it 'runs cleanup' do
        allow(GoodJob).to receive(:cleanup_preserved_jobs)

        performed_jobs = 0
        total_jobs = 2
        allow(performer).to receive(:next) do
          performed_jobs += 1
          performed_jobs < total_jobs
        end

        scheduler = described_class.new(performer, cleanup_interval_jobs: 2)
        4.times { scheduler.create_thread }
        wait_until(max: 1) { expect(performer).not_to have_received(:cleanup) }
        scheduler.shutdown

        performed_jobs = 0
        total_jobs = 4
        allow(performer).to receive(:next) do
          performed_jobs += 1
          performed_jobs < total_jobs
        end

        scheduler = described_class.new(performer, cleanup_interval_jobs: 2)
        4.times { scheduler.create_thread }
        wait_until(max: 1) { expect(performer).to have_received(:cleanup) }
        scheduler.shutdown
      end
    end
  end

  describe '.from_configuration' do
    describe 'multi-scheduling' do
      it 'instantiates multiple schedulers' do
        configuration = GoodJob::Configuration.new({ queues: '*:1;mice,ferrets:2;elephant:4' })
        multi_scheduler = described_class.from_configuration(configuration)

        all_scheduler, rodents_scheduler, elephants_scheduler = multi_scheduler.schedulers

        expect(all_scheduler.stats).to include(
          queues: '*',
          max_threads: 1
        )

        expect(rodents_scheduler.stats).to include(
          queues: 'mice,ferrets',
          max_threads: 2
        )

        expect(elephants_scheduler.stats).to include(
          queues: 'elephant',
          max_threads: 4
        )
      end
    end
  end
end
