require 'spec_helper'
require 'sidekiq/reliable_fetcher'

describe Sidekiq::ReliableFetcher do
  before do
    Sidekiq.redis = { url: REDIS_URL }
    Sidekiq.redis(&:flushdb)
  end

  after do
    Sidekiq.redis = REDIS
  end

  shared_examples 'Sidekiq fetcher' do
    let(:queues) { ['basic'] }

    describe '#retrieve_work' do
      it 'retrieves the job and puts it to working queue' do
        Sidekiq.redis { |conn| conn.rpush('queue:basic', 'msg') }

        uow = fetcher.retrieve_work

        expect(working_queue_size('basic')).to eq 1
        expect(uow.queue_name).to eq 'basic'
        expect(uow.job).to eq 'msg'
        expect(Sidekiq::Queue.new('basic').size).to eq 0
      end

      it 'does not retrieve a job from foreign queue' do
        Sidekiq.redis { |conn| conn.rpush('queue:foreign', 'msg') }

        expect(fetcher.retrieve_work).to be_nil
      end

      it 'requeues jobs from dead working queue' do
        Sidekiq.redis do |conn|
          conn.rpush(other_process_working_queue_name('basic'), 'msg')
        end

        uow = fetcher.retrieve_work

        expect(uow.job).to eq 'msg'

        Sidekiq.redis do |conn|
          expect(conn.llen(other_process_working_queue_name('basic'))).to eq 0
        end
      end

      it 'does not requeue jobs from live working queue' do
        working_queue = live_other_process_working_queue_name('basic')

        Sidekiq.redis do |conn|
          conn.rpush(working_queue, 'msg')
        end

        uow = fetcher.retrieve_work

        expect(uow).to be_nil

        Sidekiq.redis do |conn|
          expect(conn.llen(working_queue)).to eq 1
        end
      end

      it 'does not clean up orphaned jobs more than once per cleanup interval' do
        expect(described_class).to receive(:clean_working_queues!).once

        threads = []
        10.times do
          threads << Thread.new do
            described_class.new(queues: ['basic']).retrieve_work
          end
        end
        threads.map(&:join)
      end
    end
  end

  describe 'UnitOfWork' do
    let(:fetcher) { described_class.new(queues: ['basic']) }

    describe '#requeue' do
      it 'requeues job' do
        Sidekiq.redis { |conn| conn.rpush('queue:basic', 'msg') }

        uow = fetcher.retrieve_work

        uow.requeue

        expect(Sidekiq::Queue.new('basic').size).to eq 1
        expect(working_queue_size('basic')).to eq 0
      end
    end

    describe '#acknowledge' do
      it 'acknowledges job' do
        Sidekiq.redis { |conn| conn.rpush('queue:basic', 'msg') }

        uow = fetcher.retrieve_work

        expect{ uow.acknowledge }.to change{ working_queue_size('basic') }.by(-1)

        expect(Sidekiq::Queue.new('basic').size).to eq 0
      end
    end
  end

  context 'Reliable fetcher' do
    let(:fetcher) { described_class.new(queues: queues) }

    include_examples 'Sidekiq fetcher'
  end

  context 'Semi-reliable fetcher' do
    let(:fetcher) { described_class.new(semi_reliable_fetch: true, queues: queues) }

    include_examples 'Sidekiq fetcher'
  end

  describe '.bulk_requeue' do
    it 'requeues the bulk' do
      queue1 = Sidekiq::Queue.new('foo')
      queue2 = Sidekiq::Queue.new('bar')

      expect(queue1.size).to eq 0
      expect(queue2.size).to eq 0

      uow = described_class::UnitOfWork
      jobs = [ uow.new('queue:foo', 'bob'), uow.new('queue:foo', 'bar'), uow.new('queue:bar', 'widget') ]
      described_class.bulk_requeue(jobs, { queues: [] })

      expect(queue1.size).to eq 2
      expect(queue2.size).to eq 1
    end
  end

  it 'sets heartbeat' do
    config = double(:sidekiq_config, options: {})

    heartbeat_thread = described_class.setup_reliable_fetch!(config)

    Sidekiq.redis do |conn|
      sleep 0.2 # Give the time to heartbeat thread to make a loop
      heartbeat = conn.get(described_class.heartbeat_key(Socket.gethostname, ::Process.pid))

      expect(heartbeat).not_to be_nil
    end

    heartbeat_thread.kill
  end

  def working_queue_size(queue_name)
    Sidekiq.redis {|c| c.llen(described_class.working_queue_name("queue:#{queue_name}")) }
  end

  def other_process_working_queue_name(queue)
    "#{described_class::WORKING_QUEUE}:queue:#{queue}:#{Socket.gethostname}:#{::Process.pid + 1}"
  end

  def live_other_process_working_queue_name(queue)
    pid = ::Process.pid + 1
    hostname = Socket.gethostname

    Sidekiq.redis do |conn|
      conn.set(described_class.heartbeat_key(hostname, pid), 1)
    end

    "#{described_class::WORKING_QUEUE}:queue:#{queue}:#{hostname}:#{pid}"
  end
end
