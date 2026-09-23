#!/usr/bin/env rake
require "bundler/gem_tasks"

require 'rake/testtask'
Rake::TestTask.new(:test) do |test|
    test.libs << 'lib' << 'test'
    test.pattern = 'test/plugin/**/test_*.rb'
    test.verbose = true
end

desc "Integration tests against a real Redis server (see test/integration for setup)"
Rake::TestTask.new('test:integration') do |test|
    test.libs << 'lib' << 'test'
    test.pattern = 'test/integration/**/test_*.rb'
    test.verbose = true
end

task :default => :test
