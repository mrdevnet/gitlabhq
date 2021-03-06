# The ReactiveCaching concern is used to fetch some data in the background and
# store it in the Rails cache, keeping it up-to-date for as long as it is being
# requested.  If the data hasn't been requested for +reactive_cache_lifetime+,
# it stop being refreshed, and then be removed.
#
# Example of use:
#
#    class Foo < ActiveRecord::Base
#      include ReactiveCaching
#
#      self.reactive_cache_key = ->(thing) { ["foo", thing.id] }
#
#      after_save :clear_reactive_cache!
#
#      def calculate_reactive_cache
#        # Expensive operation here. The return value of this method is cached
#      end
#
#      def result
#        with_reactive_cache do |data|
#          # ...
#        end
#      end
#    end
#
# In this example, the first time `#result` is called, it will return `nil`.
# However, it will enqueue a background worker to call `#calculate_reactive_cache`
# and set an initial cache lifetime of ten minutes.
#
# Each time the background job completes, it stores the return value of
# `#calculate_reactive_cache`. It is also re-enqueued to run again after
# `reactive_cache_refresh_interval`, so keeping the stored value up to date.
# Calculations are never run concurrently.
#
# Calling `#result` while a value is in the cache will call the block given to
# `#with_reactive_cache`, yielding the cached value. It will also extend the
# lifetime by `reactive_cache_lifetime`.
#
# Once the lifetime has expired, no more background jobs will be enqueued and
# calling `#result` will again return `nil` - starting the process all over
# again
module ReactiveCaching
  extend ActiveSupport::Concern

  included do
    class_attribute :reactive_cache_lease_timeout

    class_attribute :reactive_cache_key
    class_attribute :reactive_cache_lifetime
    class_attribute :reactive_cache_refresh_interval

    # defaults
    self.reactive_cache_lease_timeout = 2.minutes

    self.reactive_cache_refresh_interval = 1.minute
    self.reactive_cache_lifetime = 10.minutes

    def calculate_reactive_cache
      raise NotImplementedError
    end

    def with_reactive_cache(&blk)
      within_reactive_cache_lifetime do
        data = Rails.cache.read(full_reactive_cache_key)
        yield data if data.present?
      end
    ensure
      Rails.cache.write(full_reactive_cache_key('alive'), true, expires_in: self.class.reactive_cache_lifetime)
      ReactiveCachingWorker.perform_async(self.class, id)
    end

    def clear_reactive_cache!
      Rails.cache.delete(full_reactive_cache_key)
    end

    def exclusively_update_reactive_cache!
      locking_reactive_cache do
        within_reactive_cache_lifetime do
          enqueuing_update do
            value = calculate_reactive_cache
            Rails.cache.write(full_reactive_cache_key, value)
          end
        end
      end
    end

    private

    def full_reactive_cache_key(*qualifiers)
      prefix = self.class.reactive_cache_key
      prefix = prefix.call(self) if prefix.respond_to?(:call)

      ([prefix].flatten + qualifiers).join(':')
    end

    def locking_reactive_cache
      lease = Gitlab::ExclusiveLease.new(full_reactive_cache_key, timeout: reactive_cache_lease_timeout)
      uuid = lease.try_obtain
      yield if uuid
    ensure
      Gitlab::ExclusiveLease.cancel(full_reactive_cache_key, uuid)
    end

    def within_reactive_cache_lifetime
      yield if Rails.cache.read(full_reactive_cache_key('alive'))
    end

    def enqueuing_update
      yield
    ensure
      ReactiveCachingWorker.perform_in(self.class.reactive_cache_refresh_interval, self.class, id)
    end
  end
end
