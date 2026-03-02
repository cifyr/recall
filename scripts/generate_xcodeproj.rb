#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'pathname'
require 'xcodeproj'

ROOT = Pathname.new(File.expand_path('..', __dir__))
APP_ROOT = ROOT.join('apps', 'AppleWatchRecorder')
PROJECT_PATH = APP_ROOT.join('AppleWatchRecorder.xcodeproj')
WORKSPACE_PATH = APP_ROOT.join('AppleWatchRecorder.xcworkspace')

FileUtils.rm_rf(PROJECT_PATH) if PROJECT_PATH.exist?
FileUtils.mkdir_p(APP_ROOT)

project = Xcodeproj::Project.new(PROJECT_PATH.to_s)
project.root_object.attributes['LastSwiftUpdateCheck'] = '2600'
project.root_object.attributes['LastUpgradeCheck'] = '2600'

main_group = project.main_group
app_group = main_group.new_group('AppleWatchRecorder', '.')
shared_group = app_group.new_group('Shared')
iphone_group = app_group.new_group('iPhoneApp')
watch_extension_group = app_group.new_group('WatchExtension')
tests_group = app_group.new_group('Tests')
resources_group = app_group.new_group('Resources')

iphone_target = project.new_target(:application, 'AppleWatchRecorder', :ios, '17.0')
watch_target = project.new_target(:application, 'WatchRecorder', :watchos, '10.0')
tests_target = project.new_target(:unit_test_bundle, 'AppleWatchRecorderTests', :ios, '17.0')
tests_target.add_dependency(iphone_target)
iphone_target.add_dependency(watch_target)

embed_watch_phase = iphone_target.new_copy_files_build_phase('Embed Watch Content')
embed_watch_phase.symbol_dst_subfolder_spec = :products_directory
embed_watch_phase.dst_path = '$(CONTENTS_FOLDER_PATH)/Watch'
embed_watch_phase.add_file_reference(watch_target.product_reference, true)

def add_swift_package(project, target, repository_url, requirement, product_name)
  package = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
  package.repositoryURL = repository_url
  package.requirement = requirement
  project.root_object.package_references << package

  product_dependency = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  product_dependency.package = package
  product_dependency.product_name = product_name
  target.package_product_dependencies << product_dependency

  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = product_dependency
  target.frameworks_build_phase.files << build_file
end

[
  [iphone_target, {
    'PRODUCT_BUNDLE_IDENTIFIER' => 'com.caden.watchrecorder',
    'INFOPLIST_FILE' => 'Resources/iPhone-Info.plist',
    'CODE_SIGN_ENTITLEMENTS' => 'Resources/AppleWatchRecorder.entitlements',
    'PRODUCT_NAME' => 'AppleWatchRecorder',
    'SWIFT_VERSION' => '6.0',
    'TARGETED_DEVICE_FAMILY' => '1,2',
    'IPHONEOS_DEPLOYMENT_TARGET' => '17.0',
    'GENERATE_INFOPLIST_FILE' => 'NO',
  }],
  [watch_target, {
    'PRODUCT_BUNDLE_IDENTIFIER' => 'com.caden.watchrecorder.watchkitapp',
    'INFOPLIST_FILE' => 'Resources/watchOS-Info.plist',
    'PRODUCT_NAME' => 'WatchRecorder',
    'SWIFT_VERSION' => '6.0',
    'WATCHOS_DEPLOYMENT_TARGET' => '10.0',
    'WK_COMPANION_APP_BUNDLE_IDENTIFIER' => 'com.caden.watchrecorder',
    'GENERATE_INFOPLIST_FILE' => 'NO',
  }],
  [tests_target, {
    'PRODUCT_BUNDLE_IDENTIFIER' => 'com.caden.watchrecorder.tests',
    'PRODUCT_NAME' => 'AppleWatchRecorderTests',
    'SWIFT_VERSION' => '6.0',
    'GENERATE_INFOPLIST_FILE' => 'YES',
    'TEST_HOST' => '$(BUILT_PRODUCTS_DIR)/AppleWatchRecorder.app/AppleWatchRecorder',
    'BUNDLE_LOADER' => '$(TEST_HOST)',
  }],
].each do |target, settings|
  target.build_configurations.each do |config|
    config.build_settings['SWIFT_EMIT_LOC_STRINGS'] = 'YES'
    config.build_settings['CODE_SIGN_STYLE'] = 'Automatic'
    config.build_settings['MARKETING_VERSION'] = '1.0'
    config.build_settings['CURRENT_PROJECT_VERSION'] = '1'
    settings.each { |key, value| config.build_settings[key] = value }
  end
end

def add_files(group, target, root_path)
  Dir.glob(File.join(root_path, '**', '*.swift')).sort.each do |file_path|
    relative_path = Pathname.new(file_path).relative_path_from(APP_ROOT).to_s
    file_ref = group.find_file_by_path(relative_path) || group.new_file(relative_path)
    target.source_build_phase.add_file_reference(file_ref, true)
  end
end

add_files(shared_group, iphone_target, APP_ROOT.join('Shared').to_s)
add_files(iphone_group, iphone_target, APP_ROOT.join('iPhoneApp').to_s)

[
  APP_ROOT.join('Shared', 'Domain', 'Models').to_s,
  APP_ROOT.join('Shared', 'Domain', 'UseCases').to_s,
  APP_ROOT.join('Shared', 'Shared', 'Utilities').to_s,
  APP_ROOT.join('Shared', 'Data', 'WatchConnectivity').to_s,
  APP_ROOT.join('WatchExtension').to_s,
].each do |path|
  add_files(watch_extension_group, watch_target, path)
end

Dir.glob(APP_ROOT.join('Tests', '**', '*.swift').to_s).sort.each do |file_path|
  relative_path = Pathname.new(file_path).relative_path_from(APP_ROOT).to_s
  file_ref = tests_group.find_file_by_path(relative_path) || tests_group.new_file(relative_path)
  tests_target.source_build_phase.add_file_reference(file_ref, true)
end

[
  'Resources/iPhone-Info.plist',
  'Resources/watchOS-Info.plist',
  'Resources/AppleWatchRecorder.entitlements',
].each do |resource_path|
  resources_group.new_file(resource_path)
end

add_swift_package(
  project,
  iphone_target,
  'https://github.com/supabase/supabase-swift.git',
  { 'kind' => 'upToNextMajorVersion', 'minimumVersion' => '2.29.0' },
  'Supabase'
)
add_swift_package(
  project,
  iphone_target,
  'https://github.com/groue/GRDB.swift.git',
  { 'kind' => 'upToNextMajorVersion', 'minimumVersion' => '7.0.0' },
  'GRDB'
)

project.save

FileUtils.mkdir_p(WORKSPACE_PATH)
workspace_contents = <<~XML
  <?xml version="1.0" encoding="UTF-8"?>
  <Workspace
     version = "1.0">
     <FileRef
        location = "group:AppleWatchRecorder.xcodeproj">
     </FileRef>
  </Workspace>
XML
File.write(WORKSPACE_PATH.join('contents.xcworkspacedata'), workspace_contents)
