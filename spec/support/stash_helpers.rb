# frozen_string_literal: true

module StashHelpers
  # A stash of its own, built like the app's but with `overrides` on top of config.query_stash.
  def build_stash(adapter, **overrides)
    config = ActiveSupport::OrderedOptions.new
    config.query_stash = ActiveSupport::OrderedOptions.new
                                                      .update(Rails.application.config.query_stash)
                                                      .update(overrides)

    with_wrap(QueryStash::Railtie.build(adapter, config))
  end

  # The specs of the ActiveRecord stash call `wrap`, which only the stash of the Rails up to 8.1 has: give
  # it to the stash whatever the Rails in use.
  def with_wrap(stash)
    stash.extend(QueryStash::ActiveRecord::InternalExecQuery::Stash) if stash.is_a?(QueryStash::ActiveRecord)
    stash
  end

  # The payloads of the `name` notifications the block emits.
  def events_of(name)
    events = []
    subscriber = ActiveSupport::Notifications.subscribe(name) { |event| events << event.payload }
    yield
    events
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  # The app's own stash, with its rules and default store emptied.
  def reset_app_stash(adapter)
    with_wrap(adapter[Rails.application]).tap do |stash|
      stash.registry.instance_variable_set(:@rules, [])
      stash.cache.clear
    end
  end
end

RSpec.configure do |config|
  config.include StashHelpers
end
