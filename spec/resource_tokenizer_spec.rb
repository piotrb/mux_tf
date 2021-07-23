RSpec.describe ResourceTokenizer do
  describe ".split" do
    let(:result) { ResourceTokenizer.split(input) }

    context do
      let(:input) { %(module.build.module.build-chain["pod-manager"].module.build.aws_s3_bucket_object.script["build-docker-image"]) }
      let(:expected) { ["module", "build", "module", "build-chain", '["pod-manager"]', "module", "build", "aws_s3_bucket_object", "script", '["build-docker-image"]'] }

      example do
        expect(result).to eq(expected)
      end
    end

    context do
      let(:input) { %(module.build.module.build-chain["pod-manager"].module.build.aws_iam_role_policy.cache_access_policy[0]) }
      let(:expected) { ["module", "build", "module", "build-chain", '["pod-manager"]', "module", "build", "aws_iam_role_policy", "cache_access_policy", "[0]"] }

      example do
        expect(result).to eq(expected)
      end
    end
  end

  describe ".tokenize" do
    let(:result) { ResourceTokenizer.tokenize(input) }

    context do
      let(:input) { %(module.build.module.build-chain["pod-manager"].module.build.aws_s3_bucket_object.script["build-docker-image"]) }
      let(:expected) {
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
      }

      example do
        expect(result).to eq(expected)
      end
    end

    context do
      let(:input) { %(module.build.module.build-chain["pod-manager"].module.build.aws_iam_role_policy.cache_access_policy[0]) }
      let(:expected) {
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
      }

      example do
        expect(result).to eq(expected)
      end
    end
  end
end
