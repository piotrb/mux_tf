# frozen_string_literal: true

RSpec.describe MuxTf::ResourceTokenizer do
  describe ".split" do
    let(:result) { described_class.split(input) }

    context "with example1" do
      let(:input) do
        %(module.build.module.build-chain["pod-manager"].module.build.aws_s3_bucket_object.script["build-docker-image"])
      end
      let(:expected) do
        ["module",
         "build",
         "module",
         "build-chain",
         '["pod-manager"]',
         "module",
         "build",
         "aws_s3_bucket_object",
         "script",
         '["build-docker-image"]']
      end

      example do
        expect(result).to eq(expected)
      end
    end

    context "with example2" do
      let(:input) do
        %(module.build.module.build-chain["pod-manager"].module.build.aws_iam_role_policy.cache_access_policy[0])
      end
      let(:expected) do
        ["module",
         "build",
         "module",
         "build-chain",
         '["pod-manager"]',
         "module",
         "build",
         "aws_iam_role_policy",
         "cache_access_policy",
         "[0]"]
      end

      example do
        expect(result).to eq(expected)
      end
    end
  end

  describe ".tokenize" do
    let(:result) { described_class.tokenize(input) }

    context "with example1" do
      let(:input) do
        %(module.build.module.build-chain["pod-manager"].module.build.aws_s3_bucket_object.script["build-docker-image"])
      end
      let(:expected) do
        [
          [:rt, "module"],
          [:rn, "build"],
          [:rt, "module"],
          [:rn, "build-chain"],
          [:ri, '["pod-manager"]'],
          [:rt, "module"],
          [:rn, "build"],
          [:rt, "aws_s3_bucket_object"],
          [:rn, "script"],
          [:ri, '["build-docker-image"]']
        ]
      end

      example do
        expect(result).to eq(expected)
      end
    end

    context "with example2" do
      let(:input) do
        %(module.build.module.build-chain["pod-manager"].module.build.aws_iam_role_policy.cache_access_policy[0])
      end
      let(:expected) do
        [
          [:rt, "module"],
          [:rn, "build"],
          [:rt, "module"],
          [:rn, "build-chain"],
          [:ri, '["pod-manager"]'],
          [:rt, "module"],
          [:rn, "build"],
          [:rt, "aws_iam_role_policy"],
          [:rn, "cache_access_policy"],
          [:ri, "[0]"]
        ]
      end

      example do
        expect(result).to eq(expected)
      end
    end

    context "with example3" do
      let(:input) { %(module.pod.module.jane.datadog_monitor.redis_event) }
      let(:expected) do
        [
          [:rt, "module"],
          [:rn, "pod"],
          [:rt, "module"],
          [:rn, "jane"],
          [:rt, "datadog_monitor"],
          [:rn, "redis_event"]
        ]
      end

      example do
        expect(result).to eq(expected)
      end
    end
  end
end
