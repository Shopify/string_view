# Contributing to StringView

We welcome bug fixes and contributions from the community.

## Reporting Issues

Please open a [GitHub issue](https://github.com/Shopify/string_view/issues) if you encounter a bug or have a feature request. Include steps to reproduce the issue when possible.

## Submitting Pull Requests

1. Fork the repository and create your branch from `main`.
2. Ensure your code compiles without warnings (`bundle exec rake compile`).
3. Add tests for any new functionality.
4. Ensure the test suite passes (`bundle exec rake test`).
5. Ensure RuboCop passes (`bundle exec rubocop`).
6. Submit your pull request.

## Development Setup

```bash
git clone https://github.com/Shopify/string_view
cd string_view
bundle install
bundle exec rake compile
bundle exec rake test
```

## Running Benchmarks

```bash
bundle exec rake compile
ruby --yjit -Ilib benchmark/bench.rb
```

## Code of Conduct

This project is governed by the [Contributor Code of Conduct](CODE_OF_CONDUCT.md).
By participating, you are expected to uphold this code. Please report unacceptable
behavior to <opensource@shopify.com>.
