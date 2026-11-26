#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_xcodeproj.py — 零依赖生成 NFCCardLab.xcodeproj

不装 xcodegen、不开 Xcode，纯 Python 写出一份合法的 project.pbxproj。
生成后可以直接 `open NFCCardLab.xcodeproj`，也可以被 xcodebuild 直接吃。

用法
  python3 tools/gen_xcodeproj.py                     # 输出到 ./NFCCardLab.xcodeproj
  python3 tools/gen_xcodeproj.py --team ABC1234567 --bundle-id com.foo.nfclab
  python3 tools/gen_xcodeproj.py -o /tmp/x.xcodeproj
"""

import argparse
import hashlib
import os
import sys

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def uid(*parts):
    """稳定 24 位 hex ID：同样的输入永远给同样的 ID，重跑不会产生 diff"""
    h = hashlib.sha1("::".join(parts).encode()).hexdigest()
    return h[:24].upper()


def collect_sources(root):
    out = []
    src = os.path.join(root, "Sources")
    for name in sorted(os.listdir(src)):
        if name.endswith(".swift"):
            out.append(os.path.join("Sources", name))
    return out


TEMPLATE = """// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{
	}};
	objectVersion = 56;
	objects = {{

/* Begin PBXBuildFile section */
{build_files}
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
{file_refs}
/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
		{frameworks_phase} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		{main_group} = {{
			isa = PBXGroup;
			children = (
				{sources_group} /* Sources */,
				{products_group} /* Products */,
			);
			sourceTree = "<group>";
		}};
		{sources_group} /* Sources */ = {{
			isa = PBXGroup;
			children = (
{source_children}
			);
			path = Sources;
			sourceTree = "<group>";
		}};
		{products_group} /* Products */ = {{
			isa = PBXGroup;
			children = (
				{product_ref} /* NFCCardLab.app */,
			);
			name = Products;
			sourceTree = "<group>";
		}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		{target} /* NFCCardLab */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {target_cfglist} /* Build configuration list for PBXNativeTarget "NFCCardLab" */;
			buildPhases = (
				{sources_phase} /* Sources */,
				{frameworks_phase} /* Frameworks */,
				{resources_phase} /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = NFCCardLab;
			productName = NFCCardLab;
			productReference = {product_ref} /* NFCCardLab.app */;
			productType = "com.apple.product-type.application";
		}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		{project} /* Project object */ = {{
			isa = PBXProject;
			attributes = {{
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 1500;
				LastUpgradeCheck = 1500;
				TargetAttributes = {{
					{target} = {{
						CreatedOnToolsVersion = 15.0;
					}};
				}};
			}};
			buildConfigurationList = {project_cfglist} /* Build configuration list for PBXProject "NFCCardLab" */;
			compatibilityVersion = "Xcode 14.0";
			developmentRegion = zh_CN;
			hasScannedForEncodings = 0;
			knownRegions = (
				zh_CN,
				en,
				Base,
			);
			mainGroup = {main_group};
			productRefGroup = {products_group} /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				{target} /* NFCCardLab */,
			);
		}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		{resources_phase} /* Resources */ = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		{sources_phase} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
{build_file_refs}
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
		{project_debug} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{project_settings}
			}};
			name = Debug;
		}};
		{project_release} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{project_settings}
			}};
			name = Release;
		}};
		{target_debug} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{target_settings}
			}};
			name = Debug;
		}};
		{target_release} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{target_settings}
			}};
			name = Release;
		}};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		{project_cfglist} /* Build configuration list for PBXProject "NFCCardLab" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{project_debug} /* Debug */,
				{project_release} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
		{target_cfglist} /* Build configuration list for PBXNativeTarget "NFCCardLab" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{target_debug} /* Debug */,
				{target_release} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
/* End XCConfigurationList section */
	}};
	rootObject = {project} /* Project object */;
}}
"""


SCHEME_TEMPLATE = """<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1500" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{target}"
               BuildableName = "NFCCardLab.app"
               BlueprintName = "NFCCardLab"
               ReferencedContainer = "container:NFCCardLab.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target}"
            BuildableName = "NFCCardLab.app"
            BlueprintName = "NFCCardLab"
            ReferencedContainer = "container:NFCCardLab.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target}"
            BuildableName = "NFCCardLab.app"
            BlueprintName = "NFCCardLab"
            ReferencedContainer = "container:NFCCardLab.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""


def build(root, team, bundle_id, swift_flags):
    sources = collect_sources(root)

    ids = {
        "project": uid("project"),
        "target": uid("target"),
        "main_group": uid("group", "main"),
        "sources_group": uid("group", "sources"),
        "products_group": uid("group", "products"),
        "product_ref": uid("ref", "NFCCardLab.app"),
        "sources_phase": uid("phase", "sources"),
        "frameworks_phase": uid("phase", "frameworks"),
        "resources_phase": uid("phase", "resources"),
        "project_cfglist": uid("cfglist", "project"),
        "target_cfglist": uid("cfglist", "target"),
        "project_debug": uid("cfg", "project", "debug"),
        "project_release": uid("cfg", "project", "release"),
        "target_debug": uid("cfg", "target", "debug"),
        "target_release": uid("cfg", "target", "release"),
    }

    build_files, file_refs, src_children, bf_refs = [], [], [], []

    # 源码
    for rel in sources:
        name = os.path.basename(rel)
        ref = uid("ref", rel)
        bf = uid("bf", rel)
        file_refs.append(
            f"\t\t{ref} /* {name} */ = {{isa = PBXFileReference; "
            f"lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = \"<group>\"; }};"
        )
        build_files.append(
            f"\t\t{bf} /* {name} in Sources */ = {{isa = PBXBuildFile; "
            f"fileRef = {ref} /* {name} */; }};"
        )
        src_children.append(f"\t\t\t\t{ref} /* {name} */,")
        bf_refs.append(f"\t\t\t\t{bf} /* {name} in Sources */,")

    # 产品引用
    file_refs.append(
        f"\t\t{ids['product_ref']} /* NFCCardLab.app */ = {{isa = PBXFileReference; "
        f"explicitFileType = wrapper.application; includeInIndex = 0; "
        f"path = NFCCardLab.app; sourceTree = BUILT_PRODUCTS_DIR; }};"
    )

    project_settings = "\n".join([
        "\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;",
        "\t\t\t\tCLANG_ENABLE_MODULES = YES;",
        "\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;",
        "\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;",
        f'\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 16.0;',
        "\t\t\t\tSDKROOT = iphoneos;",
        "\t\t\t\tSWIFT_VERSION = 5.0;",
        "\t\t\t\tONLY_ACTIVE_ARCH = NO;",
        "\t\t\t\tENABLE_BITCODE = NO;",
        "\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = \"-Onone\";",
        "\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = \"$(inherited)\";",
        "\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;",
        "\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;",
        "\t\t\t\tCOPY_PHASE_STRIP = NO;",
        "\t\t\t\tVALIDATE_PRODUCT = YES;",
    ])

    target_settings = "\n".join([
        "\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = \"\";",
        "\t\t\t\tCODE_SIGN_STYLE = Manual;",
        f'\t\t\t\tDEVELOPMENT_TEAM = "{team}";',
        f"\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = {bundle_id};",
        "\t\t\t\tPRODUCT_NAME = NFCCardLab;",
        "\t\t\t\tINFOPLIST_FILE = Resources/Info.plist;",
        "\t\t\t\tCODE_SIGN_ENTITLEMENTS = Entitlements/NFCCardLab.entitlements;",
        "\t\t\t\tTARGETED_DEVICE_FAMILY = 1;",
        "\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;",
        "\t\t\t\tGENERATE_INFOPLIST_FILE = NO;",
        "\t\t\t\tLD_RUNPATH_SEARCH_PATHS = \"$(inherited) @executable_path/Frameworks\";",
        f'\t\t\t\tOTHER_SWIFT_FLAGS = "{swift_flags}";' if swift_flags else "",
    ]).strip()

    text = TEMPLATE.format(
        build_files="\n".join(build_files),
        file_refs="\n".join(file_refs),
        source_children="\n".join(src_children),
        build_file_refs="\n".join(bf_refs),
        project_settings=project_settings,
        target_settings=target_settings,
        **ids,
    )
    return text


def main():
    ap = argparse.ArgumentParser(description="生成 NFCCardLab.xcodeproj（零依赖）")
    ap.add_argument("-r", "--root", default=HERE, help="工程根目录")
    ap.add_argument("-o", "--out", default=None, help="输出 .xcodeproj 路径")
    ap.add_argument("--team", default="TEAMID", help="DEVELOPMENT_TEAM")
    ap.add_argument("--bundle-id", default="com.local.nfclab")
    ap.add_argument("--swift-flags", default="", help="额外 OTHER_SWIFT_FLAGS，如 -DHCE_ENABLED")
    a = ap.parse_args()

    root = os.path.abspath(a.root)
    out = a.out or os.path.join(root, "NFCCardLab.xcodeproj")

    for need in ["Sources", "Resources/Info.plist", "Entitlements/NFCCardLab.entitlements"]:
        if not os.path.exists(os.path.join(root, need)):
            print(f"✗ 缺 {need}（根目录 {root}）", file=sys.stderr)
            return 1

    srcs = collect_sources(root)
    if not srcs:
        print("✗ Sources 里没有 .swift", file=sys.stderr)
        return 1

    os.makedirs(out, exist_ok=True)
    text = build(root, a.team, a.bundle_id, a.swift_flags)
    path = os.path.join(out, "project.pbxproj")
    open(path, "w", encoding="utf-8").write(text)

    print(f"✓ {path}")

    # 共享 scheme —— 没有它 xcodebuild -scheme 会报 scheme not found
    scheme_dir = os.path.join(out, "xcshareddata", "xcschemes")
    os.makedirs(scheme_dir, exist_ok=True)
    scheme_path = os.path.join(scheme_dir, "NFCCardLab.xcscheme")
    open(scheme_path, "w", encoding="utf-8").write(
        SCHEME_TEMPLATE.format(target=uid("target")))
    print(f"✓ {scheme_path}")

    print(f"  {len(srcs)} 个 Swift 文件, team={a.team}, bundle={a.bundle_id}")
    for s in srcs:
        print(f"    · {s}")
    print()
    print("下一步：")
    print(f"  open {out}")
    print("  或 xcodebuild -project NFCCardLab.xcodeproj -scheme NFCCardLab \\")
    print("       -sdk iphoneos -configuration Release CODE_SIGNING_ALLOWED=NO build")
    return 0


if __name__ == "__main__":
    sys.exit(main())
