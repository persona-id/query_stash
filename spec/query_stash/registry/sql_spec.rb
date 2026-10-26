# frozen_string_literal: true

RSpec.describe QueryStash::Registry::Sql do
  let(:registry) { described_class.new }

  describe "#add_rule" do
    it "only takes rules matched by regexp" do
      expect { registry.add_rule("SELECT", name: "x", ttl_seconds: 1, ttl_jitter_seconds: 0) }
        .to raise_error(QueryStash::Error, /Regex must be a Regexp/)
    end

    it "adds rules with regex, name, and blocks" do
      enabled = -> { true }
      registry.add_rule(/SELECT/, name: "test_rule", ttl_seconds: 60, ttl_jitter_seconds: 0, enabled: enabled)
      expect(registry.rules.length).to eq(1)
      expect(registry.rules.first.selector).to eq(/SELECT/)
      expect(registry.rules.first.name).to eq("test_rule")
      expect(registry.rules.first.enabled).to eq(enabled)

      ttl_proc = proc { 60 }
      registry.add_rule(/INSERT/, name: "proc_rule", ttl_seconds: ttl_proc, ttl_jitter_seconds: 0)
      expect(registry.rules.last.ttl_seconds).to eq(ttl_proc)

      expect(registry.rules.length).to eq(2)
    end
  end

  describe "#set_rule_defaults" do
    it "gives the rules added after it what they don't set" do
      store = Object.new
      enabled = -> { true }
      registry.set_rule_defaults(ttl_seconds: 60, ttl_jitter_seconds: 10, enabled: enabled, store: store)

      registry.add_rule(/SELECT/, name: "plain")
      registry.add_rule(/INSERT/, name: "own", ttl_seconds: 5, ttl_jitter_seconds: 0, enabled: nil, store: nil)

      expect(registry.rules.first).to have_attributes(ttl_seconds: 60, ttl_jitter_seconds: 10, enabled: enabled,
                                                      store: store)
      expect(registry.rules.last).to have_attributes(ttl_seconds: 5, ttl_jitter_seconds: 0, enabled: nil, store: nil)
    end

    it "leaves the rules that exist as they are" do
      registry.add_rule(/SELECT/, name: "before", ttl_seconds: 1, ttl_jitter_seconds: 0)
      registry.set_rule_defaults(ttl_jitter_seconds: 10)

      expect(registry.rules.first.ttl_jitter_seconds).to eq(0)
    end

    it "changes only what a later call names, and takes a default away with nil" do
      registry.set_rule_defaults(ttl_seconds: 60, ttl_jitter_seconds: 10)
      registry.set_rule_defaults(ttl_seconds: 30)
      registry.add_rule(/SELECT/, name: "one")
      registry.set_rule_defaults(ttl_jitter_seconds: nil)

      expect(registry.rules.first).to have_attributes(ttl_seconds: 30, ttl_jitter_seconds: 10)
      expect { registry.add_rule(/INSERT/, name: "two") }.to raise_error(QueryStash::Error, /needs ttl_jitter_seconds/)
    end

    it "does not take other options" do
      expect { registry.set_rule_defaults(name: "x") }.to raise_error(QueryStash::Error, /Unknown rule defaults: name/)
    end
  end

  describe "#add_rule without its ttls" do
    it "asks for them when there are no defaults" do
      expect { registry.add_rule(/SELECT/, name: "x") }.to raise_error(QueryStash::Error, /needs ttl_seconds/)
    end
  end

  describe "#delete_rule" do
    it "deletes rules by name and ignores unknown names" do
      registry.add_rule(/SELECT/, name: "test_rule", ttl_seconds: 60, ttl_jitter_seconds: 0)
      registry.add_rule(/INSERT/, name: "other_rule", ttl_seconds: 120, ttl_jitter_seconds: 0)

      registry.delete_rule("test_rule")
      expect(registry.rules.length).to eq(1)
      expect(registry.rules.map(&:name)).not_to include("test_rule")

      expect do
        registry.delete_rule("nonexistent")
      end.not_to(change { registry.rules.length })
    end
  end

  describe "#match_rule" do
    before do
      registry.add_rule(/SELECT.*users/, name: "user_queries", ttl_seconds: 60, ttl_jitter_seconds: 0)
      registry.add_rule(/SELECT.*orders/, name: "order_queries", ttl_seconds: 120, ttl_jitter_seconds: 0)
    end

    it "returns the first matching rule, or nil" do
      expect(registry.match_rule("SELECT * FROM users WHERE id = 1").name).to eq("user_queries")
      expect(registry.match_rule("SELECT * FROM products")).to be_nil

      registry.add_rule(/SELECT/, name: "generic_select", ttl_seconds: 30, ttl_jitter_seconds: 0)
      expect(registry.match_rule("SELECT * FROM users").name).to eq("user_queries")
    end
  end
end
