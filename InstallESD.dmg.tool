#!/bin/bash

InstallESD_dmg_tool () {
  echo -e "\033[31mThis tool is obsoleted, please use \033[32m$(dirname $0)/bin/iesd\033[31m instead.\033[0m"
  echo

  if [ "$(uname)" != "Darwin" ]; then
    echo "This tool is supported only on OS X." >&2
    return 1
  fi

  Help=$(cat <<EOF
usage: $0 [-b] [-v X.Y] [-i InstallESD.dmg] [-o Output.dmg] [--] [kext ...]
       $0 [-h]

OPTIONS:
  -h  Print Help (this message) and exit
  -b  Create bootable InstallESD.dmg
  -B  Use BaseSystem as container
  -i  Location of InstallESD.dmg
  -o  Location of output
  -v  Force X.Y as InstallESD version

EXAMPLE:
  $0 -i InstallESD.dmg -o Output.dmg -- NullCPUPowerManagement.kext

EOF)
  while getopts hbBi:o:v: opt; do
    case $opt in
      b)
        Bless=1
        ;;
      B)
        BaseSystem=1
        ;;
      i)
        Input_DMG=$OPTARG
        ;;
      o)
        Output_DMG=$OPTARG
        ;;
      v)
        Version=$OPTARG
        ;;
      h)
        echo "$Help"
        return 0
        ;;
      ?|:)
        echo "$Help"
        return 1
        ;;
    esac
  done

  shift $(($OPTIND - 1))
  if [ -z "$Input_DMG" ] || [ -z "$Output_DMG" ]; then
    echo "$Help" >&2
    return 1
  fi
  if [ ! -f "$Input_DMG" ]; then
    echo "InstallESD.dmg not found." >&2
    return 1
  fi
  if [ ! "$(echo "${Input_DMG##*.}" | tr "[:upper:]" "[:lower:]")" = "dmg" ]; then
    echo "Only dmg format is supported." >&2
    return 1
  fi
  if [ ! "$(echo "${Output_DMG##*.}" | tr "[:upper:]" "[:lower:]")" = "dmg" ]; then
    Output_DMG=${Output_DMG}.dmg
  fi
  if [ -e "$Output_DMG" ]; then
    echo "$Output_DMG already exists." >&2
    return 1
  fi

  Install_Kexts=( "$@" )
  if [ "${#Install_Kexts[@]}" -gt 0 ]; then
    echo
    echo "Checking Kexts"
    for Kext in "${Install_Kexts[@]}"; do
      KextBaseName=$(basename -- "$Kext")
      if [ -d "$Kext" ] && [ "${KextBaseName##*.}" = "kext" ] && [ -f "$Kext/Contents/MacOS/${KextBaseName%.*}" ]; then
        echo "✓ $KextBaseName"
      else
        echo "✗ $Kext" >&2
        return 1
      fi
    done
  fi

  Temp=$(mktemp -d "/tmp/InstallESD.dmg.kext.tool.XXXXXXXX")

  InstallESD_DMG=$Input_DMG
  InstallESD_DMG_Format=$(hdiutil imageinfo -format "$InstallESD_DMG")
  InstallESD=$Temp/InstallESD
  InstallESD_BaseSystem_DMG=$InstallESD/BaseSystem.dmg

  RW_BaseSystem_DMG=$Temp/RW_BaseSystem.dmg
  RW_BaseSystem=$Temp/RW_BaseSystem
  RW_InstallESD_DMG=$Temp/RW_InstallESD.dmg
  RW_InstallESD=$Temp/RW_InstallESD
  RW_InstallESD_BaseSystem_DMG=$RW_InstallESD/BaseSystem.dmg

  BaseSystemBinaries_PKG=$InstallESD/Packages/BaseSystemBinaries.pkg
  BaseSystemBinaries=$Temp/BaseSystemBinaries
  OSInstall_PKG=$RW_InstallESD/Packages/OSInstall.pkg
  OSInstall=$Temp/OSInstall
  OSInstall_Script=$OSInstall/Scripts/postinstall_actions/kext.tool

  Startup_kernelcache=/System/Library/Caches/com.apple.kext.caches/Startup/kernelcache
  Startup_mkext2=/System/Library/Caches/com.apple.kext.caches/Startup/Extensions.mkext
  Startup_mkext1=/System/Library/Extensions.mkext

  if [ -z "$Version" ] || [ "$(echo "$Version >= 10.7" | bc)" -eq 1 ]; then
    echo
    echo "Mounting Install ESD"
    mkdir "$InstallESD"
    hdiutil attach -quiet -nobrowse -noverify -mountpoint "$InstallESD" "$InstallESD_DMG"
    if [ "$?" -ne 0 ]; then
      hdiutil detach -quiet "$InstallESD"
      echo "Failed to mount InstallESD.dmg." >&2
      rm -rf "$Temp"
      return 1
    fi
  fi

  if [ -z "$Version" ]; then
    echo
    echo "Detecting Install ESD Version"
    if [ -f "$InstallESD_BaseSystem_DMG" ]; then
      if [ ! -f "$InstallESD/mach_kernel" ]; then
        Version=10.9
      else
        Version=10.8
        Version=10.7
        # 10.7 and 10.8 shares same structure
      fi
    elif [ -f "$InstallESD$Startup_mkext2" ]; then
      Version=10.6
    elif [ -f "$InstallESD$Startup_mkext1" ]; then
      Version=10.5
    else
      echo "Unknown InstallESD Version." >&2
      return 1
    fi
    if [ "$(echo "$Version < 10.7" | bc)" -eq 1 ]; then
      echo
      echo "Unmounting Install ESD"
      hdiutil detach -quiet "$InstallESD"
      rm -r "$InstallESD"
    fi
  fi

  if [ "$(echo "$Version >= 10.7" | bc)" -eq 1 ]; then
    InstallESD_BaseSystem_DMG_Format=$(hdiutil imageinfo -format "$InstallESD_BaseSystem_DMG")
  elif [ "$(echo "$Version >= 10.5" | bc)" -eq 1 ]; then
    InstallESD_BaseSystem_DMG=$InstallESD_DMG
    InstallESD_BaseSystem_DMG_Format=$InstallESD_DMG_Format
  fi

  if [ -n "$BaseSystem" ] || [ -f "$RW_InstallESD/System/Library/CoreServices/boot.efi" ]; then
    Bless=
  fi

  if [ "$(echo "$Version >= 10.9" | bc)" -eq 1 ]; then
    if [ "${#Install_Kexts[@]}" -gt 0 ]; then
      echo
      echo "Extracting Kernel"
      pkgutil --expand "$BaseSystemBinaries_PKG" "$BaseSystemBinaries"
      case "$(file --brief --mime-type "$BaseSystemBinaries/Payload")" in
        application/x-bzip2)
          mv "$BaseSystemBinaries/Payload" "$BaseSystemBinaries/Payload.cpio.bz2"
          bunzip2 "$BaseSystemBinaries/Payload.cpio.bz2"
          ;;
        application/x-gzip)
          mv "$BaseSystemBinaries/Payload" "$BaseSystemBinaries/Payload.cpio.gz"
          gunzip "$BaseSystemBinaries/Payload.cpio.gz"
          ;;
      esac
      echo "/mach_kernel" | cpio -p -d -I "$BaseSystemBinaries/Payload.cpio" -- "$BaseSystemBinaries/Payload"
    fi
    Mach_Kernel=$BaseSystemBinaries/Payload/mach_kernel
  elif [ "$(echo "$Version >= 10.7" | bc)" -eq 1 ]; then
    Mach_Kernel=$RW_InstallESD/mach_kernel
  elif [ "$(echo "$Version >= 10.5" | bc)" -eq 1 ]; then
    Mach_Kernel=$RW_BaseSystem/mach_kernel
  fi

  if [ "$(echo "$Version <= 10.6" | bc)" -eq 1 ] || [ -n "$BaseSystem" ]; then
    OSInstall_PKG=$RW_BaseSystem/System/Installation/Packages/OSInstall.pkg
    Mach_Kernel=$RW_BaseSystem/mach_kernel
  fi

  echo
  echo "Creating Temporary Base System in UDRW format"
  hdiutil convert -format UDRW -o "$RW_BaseSystem_DMG" "$InstallESD_BaseSystem_DMG"

  if [ -n "$BaseSystem" ]; then
    echo
    echo "Resizing Temporary Base System"
    hdiutil resize -sectors "$(( $(hdiutil resize -limits "$InstallESD_DMG" | tail -n 1 | cut -f 1) + $(hdiutil resize -limits "$InstallESD_BaseSystem_DMG" | tail -n 1 | cut -f 1) ))" "$RW_BaseSystem_DMG"
  fi

  echo
  mkdir "$RW_BaseSystem"
  echo "Mounting Temporary Base System"
  hdiutil attach -owners on -nobrowse -mountpoint "$RW_BaseSystem" "$RW_BaseSystem_DMG"

  if [ -n "$BaseSystem" ]; then
    if [ "$(echo "$Version <= 10.8" | bc)" -eq 1 ] && [ "$(echo "$Version >= 10.7" | bc)" -eq 1 ]; then
      echo
      echo "Copying Kernel"
      sudo -p "Please enter %u's password:" cp "$InstallESD/mach_kernel" "$RW_BaseSystem/mach_kernel"
    fi

    if [ "$(echo "$Version >= 10.7" | bc)" -eq 1 ]; then
      echo
      echo "Copying Packages"
      sudo -p "Please enter %u's password:" rm "$RW_BaseSystem/System/Installation/Packages"
      sudo -p "Please enter %u's password:" cp -R "$InstallESD/Packages" "$RW_BaseSystem/System/Installation/Packages"
    fi
  fi

  if [ "$(echo "$Version >= 10.7" | bc)" -eq 1 ]; then
    echo
    echo "Unmounting Install ESD"
    hdiutil detach -quiet "$InstallESD"
    rm -r "$InstallESD"
  fi

  if [ "$(echo "$Version >= 10.7" | bc)" -eq 1 ] && [ -z "$BaseSystem" ]; then
    echo
    echo "Creating Temporary Install ESD in UDRW format"
    hdiutil convert -format UDRW -ov -o "$RW_InstallESD_DMG" "$InstallESD_DMG"

    echo
    echo "Mounting Temporary Install ESD"
    mkdir "$RW_InstallESD"
    hdiutil attach -owners on -nobrowse -mountpoint "$RW_InstallESD" "$RW_InstallESD_DMG"
  fi

  if [ "${#Install_Kexts[@]}" -gt 0 ]; then
    echo
    echo "Copying Kexts"
    for Kext in "${Install_Kexts[@]}"; do
      KextBaseName=$(basename -- "$Kext")
      test -d "$RW_BaseSystem/System/Library/Extensions/$KextBaseName" && sudo -p "Please enter %u's password:" rm -rf "$RW_BaseSystem/System/Library/Extensions/$KextBaseName"
      sudo -p "Please enter %u's password:" cp -R "$Kext" "$RW_BaseSystem/System/Library/Extensions/$KextBaseName" && echo "✓ $KextBaseName"
    done

    if [ "$(echo "$Version >= 10.7" | bc)" -eq 1 ]; then
      echo
      echo "Rebuilding kernelcache"
      sudo -p "Please enter %u's password:" kextcache -v 0 -prelinked-kernel "$RW_BaseSystem$Startup_kernelcache" -kernel "$Mach_Kernel" -volume-root "$RW_BaseSystem" -- "$RW_BaseSystem/System/Library/Extensions"
    elif [ "$(echo "$Version >= 10.5" | bc)" -eq 1 ]; then
      echo
      echo "Rebuilding mkext cache"
      if [ "$(echo "$Version >= 10.6" | bc)" -eq 1 ]; then
        sudo -p "Please enter %u's password:" kextcache -v 0 -a i386 -a x86_64 -mkext "$RW_BaseSystem$Startup_mkext2" -kernel "$Mach_Kernel" -volume-root "$RW_BaseSystem" -- "$RW_BaseSystem/System/Library/Extensions"
        [ -f "$RW_BaseSystem$Startup_mkext1" ] &&
          sudo -p "Please enter %u's password:" cp "$RW_BaseSystem$Startup_mkext2" "$RW_BaseSystem$Startup_mkext1"
      else
        sudo -p "Please enter %u's password:" kextcache -v 0 -a ppc -a i386 -mkext "$RW_BaseSystem$Startup_mkext1" -kernel "$Mach_Kernel" -volume-root "$RW_BaseSystem" -- "$RW_BaseSystem/System/Library/Extensions"
      fi
    fi

    if [ "$(echo "$Version <= 10.8" | bc)" -eq 1 ] && [ "$(echo "$Version >= 10.7" | bc)" -eq 1 ] && [ -z "$BaseSystem" ]; then
      echo
      echo "Updating kernelcache on Temporary Install ESD"
      sudo -p "Please enter %u's password:" cp "$RW_BaseSystem$Startup_kernelcache" "$RW_InstallESD/kernelcache"
      sudo -p "Please enter %u's password:" chflags hidden "$RW_InstallESD/kernelcache"
    fi

    echo
    echo "Creating OSInstall Script for Kexts"
    pkgutil --expand "$OSInstall_PKG" "$OSInstall"
    touch "$OSInstall_Script" && chmod a+x "$OSInstall_Script"
    echo "#!/bin/sh" > "$OSInstall_Script"
    echo >> "$OSInstall_Script"
    for Kext in "${Install_Kexts[@]}"; do
      KextBaseName=$(basename "$Kext")
      echo "logger -p install.info \"Installing $KextBaseName\"" >> "$OSInstall_Script"
      echo "/bin/cp -R \"/System/Library/Extensions/$KextBaseName\" \"\$3/System/Library/Extensions/$KextBaseName\"" >> "$OSInstall_Script"
      echo >> "$OSInstall_Script"
    done
    echo "exit 0" >> "$OSInstall_Script"
    sudo -p "Please enter %u's password:" pkgutil --flatten "$OSInstall" "$OSInstall_PKG"
    rm -r "$OSInstall"
  fi

  if [ -n "$Bless" ]; then
    echo
    echo "Blessing Temporary Install ESD"
    sudo -p "Please enter %u's password:" mkdir -p "$RW_InstallESD/System/Library/CoreServices/com.apple.recovery.boot"
    sudo -p "Please enter %u's password:" mkdir -p "$RW_InstallESD/Library/Preferences/SystemConfiguration"
    sudo -p "Please enter %u's password:" mkdir -p "$RW_InstallESD/usr/standalone/i386/"
    sudo -p "Please enter %u's password:" cp "$RW_BaseSystem$Startup_kernelcache" "$RW_InstallESD/kernelcache"
    sudo -p "Please enter %u's password:" cp "$RW_BaseSystem/System/Library/CoreServices/Volume Name Icon" "$RW_InstallESD/System/Library/CoreServices/Volume Name Icon"
    sudo -p "Please enter %u's password:" cp "$RW_BaseSystem/System/Library/CoreServices/boot.efi" "$RW_InstallESD/usr/standalone/i386/boot.efi"
    sudo -p "Please enter %u's password:" chflags hidden "$RW_InstallESD/kernelcache" "$RW_InstallESD/System/Library/CoreServices/Volume Name Icon" "$RW_InstallESD/usr/standalone/i386/boot.efi"
    cat >"$Temp/com.apple.Boot.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Kernel Flags</key>
	<string>root-dmg=file:///BaseSystem.dmg</string>
	<key>Kernel Cache</key>
	<string>\\kernelcache</string>
</dict>
</plist>
EOF
    sudo -p "Please enter %u's password:" cp "$Temp/com.apple.Boot.plist" "$RW_InstallESD/Library/Preferences/SystemConfiguration/com.apple.Boot.plist"
    sudo -p "Please enter %u's password:" cp -R "$RW_BaseSystem/"*.app "$RW_InstallESD"
    sudo -p "Please enter %u's password:" cp "$RW_BaseSystem/System/Library/CoreServices/com.apple.recovery.boot/PlatformSupport.plist" "$RW_InstallESD/System/Library/CoreServices/com.apple.recovery.boot/PlatformSupport.plist"
    sudo -p "Please enter %u's password:" cp "$RW_BaseSystem/System/Library/CoreServices/SystemVersion.plist" "$RW_InstallESD/System/Library/CoreServices/SystemVersion.plist"
    sudo -p "Please enter %u's password:" cp "$RW_BaseSystem/System/Library/CoreServices/PlatformSupport.plist" "$RW_InstallESD/System/Library/CoreServices/PlatformSupport.plist"
    sudo -p "Please enter %u's password:" cp "$RW_BaseSystem/System/Library/CoreServices/PlatformSupport.plist" "$RW_InstallESD/System/Library/CoreServices/InstallableMachines.plist"
    sudo -p "Please enter %u's password:" /usr/libexec/PlistBuddy -c "Delete SupportedModelProperties" "$RW_InstallESD/System/Library/CoreServices/InstallableMachines.plist"
    sudo -p "Please enter %u's password:" bless --folder "$RW_InstallESD/System/Library/CoreServices" --bootefi
  fi

  echo
  echo "Unmounting Temporary Base System"
  hdiutil detach -quiet "$RW_BaseSystem"
  rm -r "$RW_BaseSystem"

  if [ -n "$Bless" ]; then
    echo
    echo "Resizing Temporary Base System"
    hdiutil resize -sectors "$(( $(hdiutil resize -limits "$RW_BaseSystem_DMG" | tail -n 1 | cut -f 1) + 262144 ))" "$RW_BaseSystem_DMG"
  fi

  if [ "$(echo "$Version >= 10.7" | bc)" -eq 1 ] && [ -z "$BaseSystem" ]; then
    echo
    echo "Converting Temporary Base System to $InstallESD_BaseSystem_DMG_Format format"
    sudo -p "Please enter %u's password:" hdiutil convert -format "$InstallESD_BaseSystem_DMG_Format" -ov -o "$RW_InstallESD_BaseSystem_DMG" "$RW_BaseSystem_DMG"
    sudo -p "Please enter %u's password:" chflags hidden "$RW_InstallESD_BaseSystem_DMG"
    rm "$RW_BaseSystem_DMG"

    echo
    echo "Unmounting Temporary Install ESD"
    hdiutil detach -quiet "$RW_InstallESD"
    rm -r "$RW_InstallESD"

    if [ -n "$Bless" ]; then
      echo
      echo "Resizing Temporary Install ESD"
      hdiutil resize -sectors "$(( $(hdiutil resize -limits "$RW_InstallESD_DMG" | tail -n 1 | cut -f 1) + 1191552 ))" "$RW_InstallESD_DMG"
    fi

    echo
    echo "Converting Temporary Install ESD to $InstallESD_DMG_Format format"
    hdiutil convert -format "$InstallESD_DMG_Format" -o "$Output_DMG" "$RW_InstallESD_DMG"
    rm "$RW_InstallESD_DMG"
  elif [ "$(echo "$Version >= 10.5" | bc)" -eq 1 ]; then
    echo
    echo "Converting Temporary Base System to $InstallESD_BaseSystem_DMG_Format format"
    hdiutil convert -format "$InstallESD_BaseSystem_DMG_Format" -o "$Output_DMG" "$RW_BaseSystem_DMG"
    rm "$RW_BaseSystem_DMG"
  fi

  rm -rf "$Temp"

  echo
  echo -e "\xF0\x9F\x8D\xBA  Done"
}

InstallESD_dmg_tool "$@"
