; SlightDroid Setup (NSIS 3). Built by tools\build\build-installer.ps1.
; Payload comes from build\payload (tools\build\stage.ps1).
Unicode true
ManifestDPIAware true
; not /SOLID: a solid block must stay under 2 GB uncompressed, and Android 11 is 3.8 GB
SetCompressor lzma
SetCompressorDictSize 64

!ifndef VERSION
  !define VERSION "0.1.0-alpha"
!endif
!ifndef PAYLOAD
  !define PAYLOAD "..\build\payload"
!endif
!ifndef OUTFILE
  !define OUTFILE "..\dist\SlightDroid-Setup-${VERSION}.exe"
!endif
!define UNINST_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\SlightDroid"
!define APP_KEY "Software\SlightDroid"

Name "SlightDroid"
OutFile "${OUTFILE}"
InstallDir "$PROGRAMFILES64\SlightDroid"
InstallDirRegKey HKLM "${APP_KEY}" "InstallDir"
RequestExecutionLevel admin
BrandingText "SlightDroid ${VERSION}"
VIProductVersion "0.1.0.0"
VIAddVersionKey "ProductName" "SlightDroid"
VIAddVersionKey "FileDescription" "SlightDroid Setup"
VIAddVersionKey "ProductVersion" "${VERSION}"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "LegalCopyright" "SlightDroid authors; see licenses"

!include "MUI2.nsh"
!include "x64.nsh"
!include "LogicLib.nsh"
!include "FileFunc.nsh"

!define MUI_ABORTWARNING
!define MUI_ICON "SlightDroid.ico"
!define MUI_UNICON "SlightDroid.ico"
!define MUI_WELCOMEFINISHPAGE_BITMAP "wizard.bmp"
!define MUI_UNWELCOMEFINISHPAGE_BITMAP "wizard.bmp"
!define MUI_WELCOMEPAGE_TITLE "Install SlightDroid"
!define MUI_WELCOMEPAGE_TEXT "SlightDroid runs Android apps on this PC.$\r$\n$\r$\nIt is built for low-end PCs (4 GB RAM). No ads, no store, no analytics.$\r$\n$\r$\nSetup checks this PC and may ask to turn on Windows Hypervisor Platform, which needs a restart.$\r$\n$\r$\nClick Next to continue."
; Start SlightDroid as the normal user, not elevated like this setup (an elevated SlightDroid can't be
; stopped/replaced by the user's own tools and gets drag-and-drop from Explorer blocked by UIPI):
; explorer.exe opens the program in the user's own unelevated session.
!define MUI_FINISHPAGE_RUN
!define MUI_FINISHPAGE_RUN_FUNCTION RunUnelevated
!define MUI_FINISHPAGE_RUN_TEXT "Start SlightDroid now"
!define MUI_FINISHPAGE_RUN_NOTCHECKED

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "${PAYLOAD}\licenses\NOTICE.txt"
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

; 64-bit system tools (Setup is a 32-bit process, so plain System32 would be redirected)
!define PS '"$WINDIR\sysnative\WindowsPowerShell\v1.0\powershell.exe"'
!define DISM '"$WINDIR\sysnative\dism.exe"'

Var Decision
Var DecisionText

; Stop a running SlightDroid: ask it to save first (quick-boot snapshot), then end only processes started from
; SlightDroid's own folder (by path, so Android Studio's emulators are never touched).
!macro STOP_SLIGHTDROID
  IfFileExists "$INSTDIR\SlightDroid.exe" 0 +2
    ExecWait '"$INSTDIR\SlightDroid.exe" --stop'
  nsExec::Exec `${PS} -NoProfile -Command "Get-Process | Where-Object { $$_.Path -like '$INSTDIR\*' } | Stop-Process -Force"`
!macroend
Function StopSlightDroid
  !insertmacro STOP_SLIGHTDROID
FunctionEnd
Function un.StopSlightDroid
  !insertmacro STOP_SLIGHTDROID
FunctionEnd

Function RunUnelevated
  Exec '"$WINDIR\explorer.exe" "$INSTDIR\SlightDroid.exe"'
FunctionEnd

Function .onInit
  ${IfNot} ${RunningX64}
    MessageBox MB_ICONSTOP "SlightDroid needs 64-bit Windows 10 (1809 or newer) or Windows 11."
    Abort
  ${EndIf}
  SetRegView 64
  ReadRegStr $0 HKLM "SOFTWARE\Microsoft\Windows NT\CurrentVersion" "CurrentBuildNumber"
  ${If} $0 < 17763
    MessageBox MB_ICONSTOP "SlightDroid needs Windows 10 version 1809 (build 17763) or newer. This PC has build $0."
    Abort
  ${EndIf}
FunctionEnd

Section "SlightDroid" SecMain
  SectionIn RO
  SetShellVarContext all
  SetRegView 64

  ; stop a running copy before overwriting files
  Call StopSlightDroid

  DetailPrint "Copying SlightDroid (this takes a few minutes on slow disks)..."
  SetOutPath "$INSTDIR"
  File "${PAYLOAD}\SlightDroid.exe"
  ; files of the earlier Android 9 engine (QEMU)
  RMDir /r "$INSTDIR\engine"
  RMDir /r "$INSTDIR\guest"
  SetOutPath "$INSTDIR\sdk"
  File /r "${PAYLOAD}\sdk\*"
  ; join the Android 11 system image (stored in 1 GB parts: the installer format has a 2 GB file limit)
  DetailPrint "Preparing the Android system image..."
  SetOutPath "$INSTDIR\sdk\system-images\android-30\default\x86_64"
  nsExec::ExecToLog '"$WINDIR\System32\cmd.exe" /c copy /y /b system.img.part0 system.img >nul && for %i in (1 2 3 4 5 6 7 8 9) do @if exist system.img.part%i copy /y /b system.img+system.img.part%i system.img >nul'
  Pop $0
  ${If} $0 != 0
    MessageBox MB_ICONSTOP "Could not prepare the Android system image (error $0). Is the disk full?"
    Abort
  ${EndIf}
  Delete "system.img.part*"
  Delete "system.img.parts"
  ; Android apps SlightDroid installs into Android itself (WebView 108, installed at first start)
  SetOutPath "$INSTDIR\apps"
  File /r "${PAYLOAD}\apps\*"
  SetOutPath "$INSTDIR\tools"
  File /r "${PAYLOAD}\tools\*"
  SetOutPath "$INSTDIR\licenses"
  File /r "${PAYLOAD}\licenses\*"
  SetOutPath "$INSTDIR"

  ; ---- shortcuts ----
  CreateDirectory "$SMPROGRAMS\SlightDroid"
  CreateShortcut "$SMPROGRAMS\SlightDroid\SlightDroid.lnk" "$INSTDIR\SlightDroid.exe"
  CreateShortcut "$SMPROGRAMS\SlightDroid\SlightDroid Files.lnk" "$INSTDIR\SlightDroid.exe" "--files"
  CreateShortcut "$SMPROGRAMS\SlightDroid\SlightDroid Settings.lnk" "$INSTDIR\SlightDroid.exe" "--settings"
  CreateShortcut "$SMPROGRAMS\SlightDroid\SlightDroid Check.lnk" "$INSTDIR\tools\envcheck.cmd" "" "$WINDIR\System32\shell32.dll" 22
  CreateShortcut "$SMPROGRAMS\SlightDroid\SlightDroid Diagnostics.lnk" "$INSTDIR\tools\diagnostics.cmd" "" "$WINDIR\System32\shell32.dll" 23
  CreateShortcut "$SMPROGRAMS\SlightDroid\Uninstall SlightDroid.lnk" "$INSTDIR\Uninstall.exe"
  CreateShortcut "$DESKTOP\SlightDroid.lnk" "$INSTDIR\SlightDroid.exe"

  ; ---- .apk files: double-click installs into SlightDroid; "Install in SlightDroid" on right-click ----
  WriteRegStr HKLM "Software\Classes\.apk" "" "SlightDroid.apk"
  WriteRegStr HKLM "Software\Classes\.apk" "Content Type" "application/vnd.android.package-archive"
  WriteRegStr HKLM "Software\Classes\SlightDroid.apk" "" "Android app (SlightDroid)"
  WriteRegStr HKLM "Software\Classes\SlightDroid.apk\DefaultIcon" "" "$INSTDIR\SlightDroid.exe,0"
  WriteRegStr HKLM "Software\Classes\SlightDroid.apk\shell\open" "" "Install in SlightDroid"
  WriteRegStr HKLM "Software\Classes\SlightDroid.apk\shell\open\command" "" '"$INSTDIR\SlightDroid.exe" --install "%1"'
  WriteRegStr HKLM "Software\Classes\SystemFileAssociations\.apk\shell\SlightDroid.install" "" "Install in SlightDroid"
  WriteRegStr HKLM "Software\Classes\SystemFileAssociations\.apk\shell\SlightDroid.install\command" "" '"$INSTDIR\SlightDroid.exe" --install "%1"'
  System::Call 'shell32::SHChangeNotify(i 0x08000000, i 0, p 0, p 0)'

  ; ---- uninstaller + Apps & features entry ----
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  WriteRegStr HKLM "${APP_KEY}" "InstallDir" "$INSTDIR"
  WriteRegStr HKLM "${APP_KEY}" "Version" "${VERSION}"
  WriteRegStr HKLM "${UNINST_KEY}" "DisplayName" "SlightDroid"
  WriteRegStr HKLM "${UNINST_KEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKLM "${UNINST_KEY}" "Publisher" "SlightDroid"
  WriteRegStr HKLM "${UNINST_KEY}" "DisplayIcon" "$INSTDIR\SlightDroid.exe"
  WriteRegStr HKLM "${UNINST_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKLM "${UNINST_KEY}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegDWORD HKLM "${UNINST_KEY}" "NoModify" 1
  WriteRegDWORD HKLM "${UNINST_KEY}" "NoRepair" 1
  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  WriteRegDWORD HKLM "${UNINST_KEY}" "EstimatedSize" $0

  ; ---- check this PC and act on the result ----
  DetailPrint "Checking this PC..."
  nsExec::ExecToStack '${PS} -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\tools\envcheck.ps1" -Decision -Json "$INSTDIR\envcheck-install.json"'
  Pop $Decision
  Pop $DecisionText
  DetailPrint "PC check result: $Decision"

  ${If} $Decision == "10"
    MessageBox MB_YESNO|MB_ICONQUESTION "SlightDroid needs the Windows feature $\"Windows Hypervisor Platform$\", which is off on this PC.$\r$\n$\r$\nTurn it on now? Windows must restart afterwards.$\r$\n$\r$\n(You can also do this later from $\"SlightDroid Check$\" in the Start menu.)" IDNO whpx_skip
      DetailPrint "Enabling Windows Hypervisor Platform..."
      nsExec::ExecToLog '${DISM} /online /enable-feature /featurename:HypervisorPlatform /all /norestart'
      Pop $0
      ${If} $0 == "0"
      ${OrIf} $0 == "3010"
        WriteRegDWORD HKLM "${APP_KEY}" "EnabledWHPX" 1
        SetRebootFlag true
        DetailPrint "Windows Hypervisor Platform enabled; restart required."
      ${Else}
        MessageBox MB_ICONEXCLAMATION "Could not turn on Windows Hypervisor Platform (DISM error $0).$\r$\nOpen $\"Turn Windows features on or off$\" and tick $\"Windows Hypervisor Platform$\", then restart."
      ${EndIf}
    whpx_skip:
  ${ElseIf} $Decision == "20"
    MessageBox MB_ICONEXCLAMATION "SlightDroid is installed, but virtualization (Intel VT-x / AMD-V) is turned OFF in this PC's BIOS/UEFI, so Android cannot start yet.$\r$\n$\r$\nTo turn it on:$\r$\n 1. Restart and open the BIOS/UEFI setup (usually F2, F10, Del or Esc at power-on).$\r$\n 2. Enable $\"Intel Virtualization Technology$\" / $\"VT-x$\" (or $\"SVM Mode$\" on AMD).$\r$\n 3. Save and exit, then run $\"SlightDroid Check$\" from the Start menu."
  ${ElseIf} $Decision == "30"
    MessageBox MB_ICONEXCLAMATION "SlightDroid is installed, but this PC may not be able to run it:$\r$\n$\r$\n$DecisionText$\r$\nRun $\"SlightDroid Check$\" from the Start menu for details."
  ${EndIf}
SectionEnd

Section "Uninstall"
  SetShellVarContext all
  SetRegView 64
  Call un.StopSlightDroid

  RMDir /r "$INSTDIR\sdk"
  RMDir /r "$INSTDIR\engine"
  RMDir /r "$INSTDIR\guest"
  RMDir /r "$INSTDIR\apps"
  RMDir /r "$INSTDIR\tools"
  RMDir /r "$INSTDIR\licenses"
  Delete "$INSTDIR\SlightDroid.exe"
  Delete "$INSTDIR\envcheck-install.json"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"

  Delete "$DESKTOP\SlightDroid.lnk"
  RMDir /r "$SMPROGRAMS\SlightDroid"

  ; .apk association: remove only what points to us
  ReadRegStr $0 HKLM "Software\Classes\.apk" ""
  ${If} $0 == "SlightDroid.apk"
    DeleteRegValue HKLM "Software\Classes\.apk" ""
  ${EndIf}
  DeleteRegKey HKLM "Software\Classes\SlightDroid.apk"
  DeleteRegKey HKLM "Software\Classes\SystemFileAssociations\.apk\shell\SlightDroid.install"
  System::Call 'shell32::SHChangeNotify(i 0x08000000, i 0, p 0, p 0)'

  SetShellVarContext current
  MessageBox MB_YESNO|MB_ICONQUESTION|MB_DEFBUTTON2 "Also delete your Android data (installed apps and their files)?$\r$\nThis cannot be undone." IDNO keep_data
    RMDir /r "$LOCALAPPDATA\SlightDroid"
  keep_data:
  SetShellVarContext all

  ReadRegDWORD $0 HKLM "${APP_KEY}" "EnabledWHPX"
  ${If} $0 == 1
    MessageBox MB_YESNO|MB_ICONQUESTION|MB_DEFBUTTON2 "SlightDroid turned on $\"Windows Hypervisor Platform$\" when it was installed.$\r$\nTurn it off again? (Other emulators or tools may need it. Restart required.)" IDNO keep_whpx
      nsExec::ExecToLog '${DISM} /online /disable-feature /featurename:HypervisorPlatform /norestart'
      SetRebootFlag true
    keep_whpx:
  ${EndIf}
  DeleteRegKey HKLM "${APP_KEY}"
  DeleteRegKey HKLM "${UNINST_KEY}"
SectionEnd
