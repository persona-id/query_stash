# frozen_string_literal: true

module StashHelpers
  # A stash of its own, built like the app's but with `overrides` on top of config.query_stash.
  def build_stash(adapter, **overrides)
    config = ActiveSupport::OrderedOptions.new
    config.query_stash = ActiveSupport::OrderedOptions.new
                                                      .update(Rails.application.config.query_stash)
                                                      .update(overrides)

    adapter.new(config).tap { |stash| built_stashes << stash }
  end

  def built_stashes
    @built_stashes ||= []
  end

  # The app's own stash, with its rules and default store emptied.
  def reset_app_stash(adapter)
    adapter[Rails.application].tap do |stash|
      stash.registry.instance_variable_set(:@rules, [])
      stash.cache.clear
    end
  end
end

RSpec.configure do |config|
  config.include StashHelpers

  # A file store's background threads outlive the example otherwise.
  config.after do
    built_stashes.map(&:cache).grep(QueryStash::FileStore).each do |store|
      store.instance_variable_get(:@metrics_thread)&.kill
      store.instance_variable_get(:@evictor_thread)&.kill
    end
  end
end
