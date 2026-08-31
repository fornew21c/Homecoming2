#!/usr/bin/env ruby
# frozen_string_literal: true

# Homecoming.xcodeproj 를 생성한다.
# xcodegen/tuist 없이 xcodeproj gem 만으로 앱 + 위젯 익스텐션 두 타겟을 구성한다.
#
#   gem install xcodeproj
#   ruby Tools/generate_project.rb

require 'xcodeproj'
require 'fileutils'
require 'pathname'

ROOT = File.expand_path('..', __dir__)
PROJECT_PATH = File.join(ROOT, 'Homecoming.xcodeproj')
APP_BUNDLE_ID = 'com.kona.homecoming2'
WIDGET_BUNDLE_ID = "#{APP_BUNDLE_ID}.widget"
DEPLOYMENT_TARGET = '17.2'   # Live Activity push-to-start 최소 버전

# 서명 팀. 없으면 실기기 빌드가 "requires a development team" 으로 죽는다.
#
# 지우기 전의 프로젝트에서 물려받는다. `HOMECOMING_TEAM_ID` 를 잊고 재생성했다가
# 실기기 빌드가 깨진 적이 있다 — 환경변수 하나를 기억해야만 되는 구조가 문제였다.
# 순서: 환경변수 → 옛 프로젝트 → 없으면 경고.
def inherited_team(project_path)
  pbxproj = File.join(project_path, 'project.pbxproj')
  return nil unless File.exist?(pbxproj)

  File.read(pbxproj)[/DEVELOPMENT_TEAM = ([A-Z0-9]+);/, 1]
end

TEAM_ID = begin
  from_env = ENV['HOMECOMING_TEAM_ID'].to_s.strip
  from_env.empty? ? inherited_team(PROJECT_PATH).to_s : from_env
end

if TEAM_ID.empty?
  warn '경고: 서명 팀을 못 찾았다. 시뮬레이터는 되지만 실기기 빌드는 실패한다.'
  warn '      HOMECOMING_TEAM_ID=XXXXXXXXXX ruby Tools/generate_project.rb'
end

FileUtils.rm_rf(PROJECT_PATH)
project = Xcodeproj::Project.new(PROJECT_PATH)

# --- 그룹 -------------------------------------------------------------------

shared_group = project.new_group('Shared', 'Shared')
app_group    = project.new_group('App', 'App')
widget_group = project.new_group('Widget', 'Widget')

# 하위 디렉터리(App/Location, App/ETA, ...)까지 훑는다.
def swift_sources(dir)
  Dir[File.join(dir, '**', '*.swift')].sort
end

shared_files = swift_sources(File.join(ROOT, 'Shared'))
app_files    = swift_sources(File.join(ROOT, 'App'))
widget_files = swift_sources(File.join(ROOT, 'Widget'))

# 그룹 트리를 실제 디렉터리 구조에 맞춰 만든다.
def add_sources(project, root_group, base_dir, files)
  cache = {}
  files.map do |path|
    rel = Pathname.new(path).relative_path_from(Pathname.new(base_dir)).dirname.to_s
    group =
      if rel == '.'
        root_group
      else
        cache[rel] ||= rel.split(File::SEPARATOR).reduce(root_group) do |parent, name|
          parent.children.find { |c| c.display_name == name && c.is_a?(Xcodeproj::Project::Object::PBXGroup) } ||
            parent.new_group(name, name)
        end
      end
    group.new_reference(path)
  end
end

shared_refs = add_sources(project, shared_group, File.join(ROOT, 'Shared'), shared_files)
app_refs    = add_sources(project, app_group,    File.join(ROOT, 'App'),    app_files)
widget_refs = add_sources(project, widget_group, File.join(ROOT, 'Widget'), widget_files)

app_group.new_reference(File.join(ROOT, 'App', 'Info.plist'))
assets_ref = app_group.new_reference(File.join(ROOT, 'App', 'Assets.xcassets'))
app_group.new_reference(File.join(ROOT, 'App', 'Homecoming.entitlements'))
widget_group.new_reference(File.join(ROOT, 'Widget', 'Info.plist'))

# 개인정보 매니페스트. **리소스로 넣어야 번들에 들어간다** — 파일만 만들어 두면
# 심사에서 없는 것과 같다. 타깃마다 하나씩이다(앱은 수집을 신고하고, 위젯은
# `Shared/` 가 쓰는 `UserDefaults` 만 신고한다).
app_privacy_ref = app_group.new_reference(File.join(ROOT, 'App', 'PrivacyInfo.xcprivacy'))
widget_privacy_ref = widget_group.new_reference(File.join(ROOT, 'Widget', 'PrivacyInfo.xcprivacy'))

# --- 공통 빌드 설정 ----------------------------------------------------------

COMMON = {
  'IPHONEOS_DEPLOYMENT_TARGET' => DEPLOYMENT_TARGET,
  'SWIFT_VERSION' => '5.0',
  'TARGETED_DEVICE_FAMILY' => '1',
  'CODE_SIGN_STYLE' => 'Automatic',
  'DEVELOPMENT_TEAM' => TEAM_ID,
  # 시뮬레이터는 ad-hoc 서명. 서명을 아예 끄면 엔타이틀먼트가 번들에 안 들어가고,
  # 그러면 Activity.request(pushType: .token) 이 ActivityInput 오류로 실패한다.
  'CODE_SIGN_IDENTITY[sdk=iphonesimulator*]' => '-',
  'GENERATE_INFOPLIST_FILE' => 'NO',
  'SWIFT_EMIT_LOC_STRINGS' => 'YES',
  'ENABLE_USER_SCRIPT_SANDBOXING' => 'YES',
  'ALWAYS_SEARCH_USER_PATHS' => 'NO',
  'CLANG_ENABLE_MODULES' => 'YES',
  'ENABLE_PREVIEWS' => 'YES'
}.freeze

project.build_configurations.each do |config|
  COMMON.each { |k, v| config.build_settings[k] = v }
  config.build_settings['SDKROOT'] = 'iphoneos'
  if config.name == 'Debug'
    config.build_settings['SWIFT_OPTIMIZATION_LEVEL'] = '-Onone'
    config.build_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = 'DEBUG'
    config.build_settings['ONLY_ACTIVE_ARCH'] = 'YES'
  else
    config.build_settings['SWIFT_OPTIMIZATION_LEVEL'] = '-O'
    config.build_settings['SWIFT_COMPILATION_MODE'] = 'wholemodule'
  end
end

# --- 앱 타겟 ----------------------------------------------------------------

app = project.new_target(:application, 'Homecoming', :ios, DEPLOYMENT_TARGET)
app.build_configurations.each do |config|
  config.build_settings.merge!(COMMON)
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = APP_BUNDLE_ID
  config.build_settings['INFOPLIST_FILE'] = 'App/Info.plist'
  config.build_settings['INFOPLIST_KEY_CFBundleDisplayName'] = '귀가마중2'
  # Push Notifications capability. 시뮬레이터 빌드는 서명이 꺼져 있어 그대로 무시된다.
  config.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'App/Homecoming.entitlements'
  config.build_settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
  config.build_settings['CURRENT_PROJECT_VERSION'] = '1'
  config.build_settings['MARKETING_VERSION'] = '1.0'
end
app.add_file_references(shared_refs + app_refs)
app.resources_build_phase.add_file_reference(assets_ref)
app.resources_build_phase.add_file_reference(app_privacy_ref)

# --- 위젯 익스텐션 타겟 -------------------------------------------------------

widget = project.new_target(:app_extension, 'HomecomingWidget', :ios, DEPLOYMENT_TARGET)
widget.build_configurations.each do |config|
  config.build_settings.merge!(COMMON)
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = WIDGET_BUNDLE_ID
  config.build_settings['INFOPLIST_FILE'] = 'Widget/Info.plist'
  config.build_settings['SKIP_INSTALL'] = 'YES'
  config.build_settings['CURRENT_PROJECT_VERSION'] = '1'
  config.build_settings['MARKETING_VERSION'] = '1.0'
  config.build_settings['LD_RUNPATH_SEARCH_PATHS'] =
    ['$(inherited)', '@executable_path/Frameworks', '@executable_path/../../Frameworks']
end
# 위젯도 Attributes 정의가 필요하므로 Shared 를 양쪽 타겟에 넣는다.
widget.add_file_references(shared_refs + widget_refs)
widget.resources_build_phase.add_file_reference(widget_privacy_ref)

# 익스텐션은 SwiftUI/WidgetKit/ActivityKit 을 명시적으로 링크한다.
%w[SwiftUI.framework WidgetKit.framework ActivityKit.framework].each do |name|
  ref = project.frameworks_group.new_file("System/Library/Frameworks/#{name}", :sdk_root)
  widget.frameworks_build_phase.add_file_reference(ref)
end

# --- 앱에 익스텐션 임베드 ------------------------------------------------------

app.add_dependency(widget)

embed = app.new_copy_files_build_phase('Embed Foundation Extensions')
embed.symbol_dst_subfolder_spec = :plug_ins
embed.dst_path = ''
build_file = embed.add_file_reference(widget.product_reference)
build_file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }

# 임베드 단계가 링크보다 뒤에 오도록 정렬
app.build_phases.delete(embed)
app.build_phases << embed

# --- 스킴 -------------------------------------------------------------------

project.save

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.set_launch_target(app)
scheme.save_as(PROJECT_PATH, 'Homecoming', true)

# --- 암묵 워크스페이스 -------------------------------------------------------
#
# Xcode 는 프로젝트를 열 때 이 파일을 스스로 만드는데, 위에서 .xcodeproj 를 통째로
# 지우니까 함께 날아간다. 그 상태로 Xcode 가 열려 있으면 프로젝트가 다시 안 열린다.
# 두 번 겪었다. 생성기가 쓰는 게 맞다.
workspace_dir = File.join(PROJECT_PATH, 'project.xcworkspace')
FileUtils.mkdir_p(workspace_dir)
File.write(File.join(workspace_dir, 'contents.xcworkspacedata'), <<~XML)
  <?xml version="1.0" encoding="UTF-8"?>
  <Workspace
     version = "1.0">
     <FileRef
        location = "self:">
     </FileRef>
  </Workspace>
XML

puts "생성 완료: #{PROJECT_PATH}"
puts "  타겟: Homecoming (#{APP_BUNDLE_ID})"
puts "  타겟: HomecomingWidget (#{WIDGET_BUNDLE_ID})"
