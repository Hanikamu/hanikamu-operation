# Base image
FROM ruby:4.0

WORKDIR "/app"

# Add our Gemfile and install gems
ADD Gemfile* ./
ADD hanikamu-operation.gemspec ./

RUN bundle install

# Copy the rest of the application
ADD . .
