# MuxTf

Terraform Module Multiplexer

## Installation

```shell
gem install mux_tf
```

## Usage

At the root folder of your terraform modules eg:

```text
ROOT/
     production/ << == HERE
                group1/
                       cluster1/
                                main.tf
                       cluster2/
                                main.tf
                group2/
                       cluster3/
                                main.tf
                       cluster4/
                                main.tf
     sandbox/ << == OR HERE
             {SIMILLAR STRUCTURE}
```

## Development

To install this gem onto your local machine, run `bundle exec rake install`.

## Releasing

To release a new version, first bump the version number by running:

```shell
gem bump -v major|minor|patch
```

And then run `rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/piotrb/mux_tf.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
