# encoding: utf-8

require "logstash-core-queue-jruby/logstash-core-queue-jruby"

# This is an adapted copy of the wrapped_synchronous_queue file
# ideally this should be moved to Java/JRuby

module LogStash; module Util
  class WrappedAckedQueue
    def initialize(path, size)
      @queue = LogStash::AckedQueue.new(path, size)
      @queue.open
    end

    # Push an object to the queue if the queue is full
    # it will block until the object can be added to the queue.
    #
    # @param [Object] Object to add to the queue
    def push(obj)
      @queue.write(obj)
    end
    alias_method(:<<, :push)

    # TODO - fix doc for this noop method
    # Offer an object to the queue, wait for the specified amount of time.
    # If adding to the queue was successful it will return true, false otherwise.
    #
    # @param [Object] Object to add to the queue
    # @param [Integer] Time in milliseconds to wait before giving up
    # @return [Boolean] True if adding was successfull if not it return false
    def offer(obj, timeout_ms)
      false
    end

    # Blocking
    def take
      # TODO - determine better arbitrary timeout millis
      @queue.read_batch(1, 200).get_elements.first
    end

    # Block for X millis
    def poll(millis)
      @queue.read_batch(1, millis).get_elements.first
    end

    def write_client
      WriteClient.new(@queue)
    end

    def read_client()
      ReadClient.new(@queue)
    end

    def close
      @queue.close
    end

    class ReadClient
      # We generally only want one thread at a time able to access pop/take/poll operations
      # from this queue. We also depend on this to be able to block consumers while we snapshot
      # in-flight buffers

      def initialize(queue, batch_size = 125, wait_for = 5)
        @queue = queue
        @mutex = Mutex.new
        # Note that @infilght_batches as a central mechanism for tracking inflight
        # batches will fail if we have multiple read clients in the pipeline.
        @inflight_batches = {}
        @batch_size = batch_size
        @wait_for = wait_for
      end

      def set_batch_dimensions(batch_size, wait_for)
        @batch_size = batch_size
        @wait_for = wait_for
      end

      def set_events_metric(metric)
        @event_metric = metric
      end

      def set_pipeline_metric(metric)
        @pipeline_metric = metric
      end

      def inflight_batches
        @mutex.synchronize do
          yield(@inflight_batches)
        end
      end

      def current_inflight_batch
        @inflight_batches.fetch(Thread.current, [])
      end

      def take_batch
        @mutex.synchronize do
          batch = ReadBatch.new(@queue, @batch_size, @wait_for)
          add_starting_metrics(batch)
          set_current_thread_inflight_batch(batch)
          batch
        end
      end

      def set_current_thread_inflight_batch(batch)
        @inflight_batches[Thread.current] = batch
      end

      def close_batch(batch)
        @mutex.synchronize do
          batch.close
          @inflight_batches.delete(Thread.current)
        end
      end

      def add_starting_metrics(batch)
        return if @event_metric.nil? || @pipeline_metric.nil?
        @event_metric.increment(:in, batch.starting_size)
        @pipeline_metric.increment(:in, batch.starting_size)
      end

      def add_filtered_metrics(batch)
        @event_metric.increment(:filtered, batch.filtered_size)
        @pipeline_metric.increment(:filtered, batch.filtered_size)
      end

      def add_output_metrics(batch)
        @event_metric.increment(:out, batch.filtered_size)
        @pipeline_metric.increment(:out, batch.filtered_size)
      end
    end

    class ReadBatch
      def initialize(queue, size, wait)
        @originals = Hash.new
        @cancelled = Hash.new
        @generated = Hash.new
        @iterating_temp = Hash.new
        @iterating = false # Atomic Boolean maybe? Although batches are not shared across threads
        take_originals_from_queue(queue, size, wait) # this sets a reference to @acked_batch
      end

      def close
        # this will ack the whole batch, regardless of whether some
        # events were cancelled or failed
        return if @acked_batch.nil?
        @acked_batch.close
      end

      def merge(event)
        return if event.nil? || @originals.key?(event)
        # take care not to cause @generated to change during iteration
        # @iterating_temp is merged after the iteration
        if iterating?
          @iterating_temp[event] = true
        else
          # the periodic flush could generate events outside of an each iteration
          @generated[event] = true
        end
      end

      def cancel(event)
        @cancelled[event] = true
      end

      def each(&blk)
        # take care not to cause @originals or @generated to change during iteration
        @iterating = true
        @originals.each do |e, _|
          blk.call(e) unless @cancelled.include?(e)
        end
        @generated.each do |e, _|
          blk.call(e) unless @cancelled.include?(e)
        end
        @iterating = false
        update_generated
      end

      def size
        filtered_size
      end

      def starting_size
        @originals.size
      end

      def filtered_size
        @originals.size + @generated.size
      end

      def cancelled_size
        @cancelled.size
      end

      def shutdown_signal_received?
        false
      end

      def flush_signal_received?
        false
      end

      private

      def iterating?
        @iterating
      end

      def update_generated
        @generated.update(@iterating_temp)
        @iterating_temp.clear
      end

      def take_originals_from_queue(queue, size, wait)
        @acked_batch = queue.read_batch(size, wait)
        return if @acked_batch.nil?
        @acked_batch.get_elements.each do |e|
          @originals[e] = true
        end
      end
    end

    class WriteClient
      def initialize(queue)
        @queue = queue
      end

      def get_new_batch
        WriteBatch.new
      end

      def push(event)
        @queue.write(event)
      end
      alias_method(:<<, :push)

      def push_batch(batch)
        batch.each do |event|
          push(event)
        end
      end
    end

    class WriteBatch
      def initialize
        @events = []
      end

      def push(event)
        @events.push(event)
      end
      alias_method(:<<, :push)

      def each(&blk)
        @events.each do |e|
          blk.call(e)
        end
      end
    end
  end
end end
