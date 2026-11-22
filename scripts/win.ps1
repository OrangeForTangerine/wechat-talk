# win.ps1 —— 微信窗口操作工具库（可被 wx.ps1 引用，也可单独调用）
# 用法：
#   . .\scripts\win.ps1
#   $h = Get-WeixinHwnd
#   Show-WeixinGeom -Hwnd $h
#   Set-WeixinGeom -Hwnd $h -X 1391 -Y 205 -W 1174 -H 1187
#   Save-WeixinShot -Hwnd $h -Path .\s.png
#
# 重要约束（本机实测）：
# 1) 必须先 SetProcessDPIAware()，否则 Screen 读到 1707x1067，而真实是 2560x1600。
# 2) 改窗口尺寸/位置只能用 MoveWindow。用 SetWindowPos 改尺寸会把微信窗口弄成 0x0。
# 3) SetWindowPos 仅用于置顶(HWND_TOPMOST=-1)/取消置顶(-2)/最小化，不要传宽高。
# 4) 客户区原点优先用 ClientToScreen，比「外框+边框推算」可靠。

Add-Type -AssemblyName System.Drawing

if (-not ('WXW' -as [type])) {
$WX_DLL = Join-Path $PSScriptRoot "wxwin.dll"

# 极速加载：预编译 DLL 存在就 Add-Type -Path（约 35ms），否则现场编译（约 315ms）并落盘
if (Test-Path $WX_DLL) {
  try {
    Add-Type -Path $WX_DLL -ErrorAction Stop
    $script:WXLoaded = $true
  } catch { $script:WXLoaded = $false }
}
if (-not $script:WXLoaded) {
$WX_SRC = @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class WXW {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int hh, bool rp);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr wp, IntPtr lp);
  [DllImport("user32.dll")] public static extern bool ScreenToClient(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern IntPtr ChildWindowFromPointEx(IntPtr h, POINT p, uint flags);
  [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);

  public struct RECT { public int L; public int T; public int R; public int B; }
  public struct POINT { public int X; public int Y; }

  public const uint KU = 0x0002;
  public const uint SWP_NOSIZE = 0x0001;
  public const uint SWP_NOMOVE = 0x0002;
  public const int HWND_TOPMOST = -1;
  public const int HWND_NOTOPMOST = -2;

  public static int ScreenW(){ return GetSystemMetrics(0); }
  public static int ScreenH(){ return GetSystemMetrics(1); }
  public static int WinX(IntPtr h){ RECT r = new RECT(); GetWindowRect(h, out r); return r.L; }
  public static int WinY(IntPtr h){ RECT r = new RECT(); GetWindowRect(h, out r); return r.T; }
  public static int WinW(IntPtr h){ RECT r = new RECT(); GetWindowRect(h, out r); return r.R - r.L; }
  public static int WinH(IntPtr h){ RECT r = new RECT(); GetWindowRect(h, out r); return r.B - r.T; }
  public static int CliW(IntPtr h){ RECT r = new RECT(); GetClientRect(h, out r); return r.R - r.L; }
  public static int CliH(IntPtr h){ RECT r = new RECT(); GetClientRect(h, out r); return r.B - r.T; }
  public static int CliX(IntPtr h){ POINT p = new POINT(); ClientToScreen(h, ref p); return p.X; }
  public static int CliY(IntPtr h){ POINT p = new POINT(); ClientToScreen(h, ref p); return p.Y; }

  public static long Find(uint[] pids) {
    long best = 0; int bestArea = 0;
    EnumWindows(delegate(IntPtr h, IntPtr l) {
      uint pid; GetWindowThreadProcessId(h, out pid);
      bool mine = false;
      for (int i = 0; i < pids.Length; i++) if (pids[i] == pid) mine = true;
      if (!mine) return true;
      StringBuilder c = new StringBuilder(256); GetClassNameW(h, c, 256);
      String cls = c.ToString();
      if (cls.IndexOf("Qt5") < 0) return true;
      if (cls.IndexOf("TrayIcon") >= 0) return true;
      if (cls.IndexOf("MessageWindow") >= 0) return true;
      RECT r = new RECT(); GetClientRect(h, out r);
      int w = r.R - r.L; int ht = r.B - r.T;
      if (w > 400 && ht > 400) { int a = w * ht; if (a > bestArea) { bestArea = a; best = h.ToInt64(); } }
      return true;
    }, IntPtr.Zero);
    return best;
  }

  public static void KeyDown(byte vk){ keybd_event(vk, 0, 0, UIntPtr.Zero); }
  public static void KeyUp(byte vk){ keybd_event(vk, 0, KU, UIntPtr.Zero); }
  public static void CtrlV(){ KeyDown(0x11); KeyDown(0x56); KeyUp(0x56); KeyUp(0x11); }
  public static void CtrlA(){ KeyDown(0x11); KeyDown(0x41); KeyUp(0x41); KeyUp(0x11); }
  public static void Bs(){ KeyDown(0x08); KeyUp(0x08); }
  public static void Enter(){ KeyDown(0x0D); KeyUp(0x0D); }
  public static void Esc(){ KeyDown(0x1B); KeyUp(0x1B); }
  // delta: -120 = 向下滚, +120 = 向上滚 (MOUSEEVENTF_WHEEL = 0x0800)
  public static void Wheel(int delta){ mouse_event(0x0800, 0, 0, (uint)(delta & 0xFFFF), IntPtr.Zero); }
  // PostMessage 版滚轮：直接投递 WM_MOUSEWHEEL，不依赖光标与前台
  public static bool WheelMsg(IntPtr hwnd, int delta, int scrX, int scrY){
    IntPtr wp = (IntPtr)((delta << 16) & 0xFFFF0000);
    IntPtr lp = (IntPtr)(((scrY & 0xFFFF) << 16) | (scrX & 0xFFFF));
    return PostMessage(hwnd, 0x020A, wp, lp);
  }
  public static IntPtr DeepChild(IntPtr hwnd, int scrX, int scrY){
    IntPtr cur = hwnd;
    for(int i=0;i<8;i++){
      POINT p = new POINT(); p.X = scrX; p.Y = scrY;
      if(!ScreenToClient(cur, ref p)) break;
      IntPtr c = ChildWindowFromPointEx(cur, p, 0x0001|0x0002);
      if(c == IntPtr.Zero || c == cur) break;
      cur = c;
    }
    return cur;
  }
  public static int CursorX(){ POINT p = new POINT(); GetCursorPos(out p); return p.X; }
  public static int CursorY(){ POINT p = new POINT(); GetCursorPos(out p); return p.Y; }

  public static void Top(IntPtr h, bool on){
    SetWindowPos(h, new IntPtr(on ? -1 : -2), 0, 0, 0, 0, SWP_NOSIZE | SWP_NOMOVE);
  }
}
'@
  try {
    Add-Type -TypeDefinition $WX_SRC -OutputAssembly $WX_DLL -OutputType Library -ErrorAction Stop
    Add-Type -Path $WX_DLL
  } catch {
    Add-Type -TypeDefinition $WX_SRC
  }
}
}

[WXW]::SetProcessDPIAware() | Out-Null

# ---------------------------------------------------------------
# 第一步：极速初始化（本 skill 的核心提速点）
# 目标：位置与几何已确认后，后续每次调用都不再探测、不再整理窗口。
# 策略：首次实测 -> 结果写 cache；后续直接读 cache，只做一次外框比对。
# 外框比对用 GetWindowRect 直读（不再「客户区 + 边框反推」，反推有取整误差）
# ---------------------------------------------------------------
# ============================================================
# 基准配置（换屏幕不用改这里：全部按屏幕宽度等比缩放）
# 标定环境：屏幕 2560x1600，窗口外框 1174x1187 @ (1391,205)
#           客户区 1152x1176，客户区原点 (1402,205)
# ============================================================
$BASE = @{
  ScrW    = 2560    # 标定屏幕宽
  ScrH    = 1600    # 标定屏幕高
  WinW    = 1174    # 标定窗口外框宽
  WinH    = 1187    # 标定窗口外框高
  WinX    = 1391    # 标定窗口外框左上 X
  WinY    = 205     # 标定窗口外框左上 Y
  CliW    = 1152    # 标定客户区宽
  CliH    = 1176    # 标定客户区高
  CliX    = 1402    # 标定客户区屏幕原点 X
  CliY    = 205     # 标定客户区屏幕原点 Y
  # 客户区内的布局基准点
  SearchX = 240; SearchY = 84      # 搜索框
  RowX    = 240; RowFirst = 270    # 结果首行中心
  RowStep = 96                     # 会话行高
  InputX  = 730; InputY = 1090     # 聊天输入区
}

$WX_CACHE = Join-Path (Split-Path -Parent $PSScriptRoot) ".wxgeom.json"

function Get-WeixinHwndFast {
  param([int]$KnownHwnd = 0)
  # 有缓存句柄先直连验证，省掉枚举进程 + EnumWindows 两趟
  if ($KnownHwnd -gt 0) {
    $h = [IntPtr]::new([long]$KnownHwnd)
    if ([WXW]::IsWindow($h)) { return $h }
  }
  return Get-WeixinHwnd
}

function Read-WxCache {
  # 一次读文件即可，不做 Test-Path（省一次 IO）
  try { return ([IO.File]::ReadAllText($WX_CACHE) | ConvertFrom-Json) } catch { return $null }
}

function Write-WxCache($obj) {
  try { ($obj | ConvertTo-Json -Compress) | Set-Content $WX_CACHE -Encoding UTF8 } catch { }
}

# 一步到位：返回可直接使用的会话上下文（含坐标），必要时才整理窗口
# -Force 仅用于确实要重新摆放窗口时
function Start-WxReady {
  param([switch]$Force)

  $cache = Read-WxCache
  $scrW = [WXW]::ScreenW()
  $scrH = [WXW]::ScreenH()

  # 句柄：缓存命中就走直连，省两趟枚举（约 60ms）
  $known = 0
  if ($cache -and $cache.hwnd) { $known = [int]$cache.hwnd }
  $hwnd = Get-WeixinHwndFast -KnownHwnd $known

  # 目标几何：一律按当前屏幕现算（缓存只用来省句柄查找，不用来决定尺寸）
  # 这样任何屏幕、任何分辨率下，窗口都保持同样的视觉占比
  $sx = $scrW / [double]$BASE.ScrW
  $sy = $scrH / [double]$BASE.ScrH
  $fixW = [int][math]::Round($BASE.WinW * $sx)
  $fixH = [int][math]::Round($BASE.WinH * $sy)
  $fixX = [int][math]::Round($BASE.WinX * $sx)
  $fixY = [int][math]::Round($BASE.WinY * $sy)

  # 只读外框，一次判断。容差 8px：不做反推，无累计误差
  $curX = [WXW]::WinX($hwnd); $curY = [WXW]::WinY($hwnd)
  $curW = [WXW]::WinW($hwnd); $curH = [WXW]::WinH($hwnd)
  $tol = 8
  $needFix = $Force -or
             ([math]::Abs($curW - $fixW) -gt $tol) -or
             ([math]::Abs($curH - $fixH) -gt $tol) -or
             ([math]::Abs($curX - $fixX) -gt $tol) -or
             ([math]::Abs($curY - $fixY) -gt $tol)

  if ($needFix) {
    Set-WeixinGeom -Hwnd $hwnd -X $fixX -Y $fixY -W $fixW -H $fixH
    Write-WxCache ([pscustomobject]@{
      hwnd = [long]$hwnd; screenW = $scrW; screenH = $scrH
      x = $fixX; y = $fixY; w = $fixW; h = $fixH
    })
  } elseif (-not $cache) {
    Write-WxCache ([pscustomobject]@{
      hwnd = [long]$hwnd; screenW = $scrW; screenH = $scrH
      x = $curX; y = $curY; w = $curW; h = $curH
    })
  }

  Set-WeixinForeground -Hwnd $hwnd

  # 客户区与预期不一致（窗口被手动改过 / 边框有差异）→ 按当前屏幕再整理一次
  $cW0 = [WXW]::CliW($hwnd); $cH0 = [WXW]::CliH($hwnd)
  $expW0 = [int][math]::Round($BASE.CliW * $sx)
  $expH0 = [int][math]::Round($BASE.CliH * $sy)
  if (-not $needFix -and ($Force -or
      ([math]::Abs($cW0 - $expW0) -gt $tol) -or ([math]::Abs($cH0 - $expH0) -gt $tol))) {
    Set-WeixinGeom -Hwnd $hwnd -X $fixX -Y $fixY -W $fixW -H $fixH
    $needFix = $true
  }

  # 客户区：尺寸与屏幕原点都现取（位置改了也不会错）
  $cW = [WXW]::CliW($hwnd); $cH = [WXW]::CliH($hwnd)
  $cx = [WXW]::CliX($hwnd); $cy = [WXW]::CliY($hwnd)

  # 按当前屏幕推算「应有客户区」，与实际值核对；差太多说明窗口被手动改过
  $expW = [int][math]::Round($BASE.CliW * $sx)
  $expH = [int][math]::Round($BASE.CliH * $sy)
  $cliOk = ([math]::Abs($cW - $expW) -le $tol) -and ([math]::Abs($cH - $expH) -le $tol)

  # 坐标一律按「实际客户区 / 基准客户区」换算，窗口真被改过也不会点偏
  $kx = $cW / [double]$BASE.CliW
  $ky = $cH / [double]$BASE.CliH
  return [pscustomobject]@{
    Hwnd = $hwnd; ClientW = $cW; ClientH = $cH; ClientX = $cx; ClientY = $cy
    ScreenW = $scrW; ScreenH = $scrH; Fixed = $needFix; CliOk = $cliOk
    ExpectW = $expW; ExpectH = $expH
    SearchX = [int][math]::Round($BASE.SearchX * $kx); SearchY = [int][math]::Round($BASE.SearchY * $ky)
    RowX    = [int][math]::Round($BASE.RowX * $kx);    RowFirst = [int][math]::Round($BASE.RowFirst * $ky)
    RowStep = [int][math]::Round($BASE.RowStep * $ky)
    InputX  = [int][math]::Round($BASE.InputX * $kx);  InputY = [int][math]::Round($BASE.InputY * $ky)
  }
}

function Reset-WxCache { Remove-Item $WX_CACHE -ErrorAction SilentlyContinue }

function Get-WeixinHwnd {
  $pids = @(Get-Process Weixin -ErrorAction SilentlyContinue | ForEach-Object { [uint32]$_.Id })
  if ($pids.Count -eq 0) { throw "微信未启动（无 Weixin 进程）" }
  $raw = [WXW]::Find($pids)
  if ($raw -le 0) { throw "未找到微信主窗口" }
  return [IntPtr]::new($raw)
}

function Get-ScreenSize {
  return @{ W = [WXW]::ScreenW(); H = [WXW]::ScreenH() }
}

function Show-WeixinGeom {
  param([IntPtr]$Hwnd)
  $s = Get-ScreenSize
  Write-Output ("SCREEN {0}x{1} | WIN {2},{3} {4}x{5} | CLIENT {6}x{7} origin={8},{9} | max={10} min={11} fg={12}" -f `
    $s.W, $s.H, [WXW]::WinX($Hwnd), [WXW]::WinY($Hwnd), [WXW]::WinW($Hwnd), [WXW]::WinH($Hwnd), `
    [WXW]::CliW($Hwnd), [WXW]::CliH($Hwnd), [WXW]::CliX($Hwnd), [WXW]::CliY($Hwnd), `
    [WXW]::IsZoomed($Hwnd), [WXW]::IsIconic($Hwnd), ([WXW]::GetForegroundWindow() -eq $Hwnd))
}

# 设置窗口外框位置与尺寸（用 MoveWindow，唯一可靠的方式）
function Set-WeixinGeom {
  param([IntPtr]$Hwnd, [int]$X, [int]$Y, [int]$W, [int]$H, [int]$Repeat = 2)
  [WXW]::ShowWindow($Hwnd, 9) | Out-Null   # SW_RESTORE
  [WXW]::ShowWindow($Hwnd, 5) | Out-Null   # SW_SHOW
  Start-Sleep -Milliseconds 120
  for ($i = 0; $i -lt $Repeat; $i++) {
    [WXW]::MoveWindow($Hwnd, $X, $Y, $W, $H, $true) | Out-Null
    Start-Sleep -Milliseconds 220
  }
  Start-Sleep -Milliseconds 500
}

function Set-WeixinForeground {
  param([IntPtr]$Hwnd)
  if ([WXW]::GetForegroundWindow() -ne $Hwnd) {
    [WXW]::SetForegroundWindow($Hwnd) | Out-Null
    Start-Sleep -Milliseconds 180
  }
}

# 置顶 -> 截图 -> 取消置顶。截到的是客户区，不含标题栏。
function Save-WeixinShot {
  param([IntPtr]$Hwnd, [string]$Path, [switch]$TopMost)
  if ($TopMost) { [WXW]::Top($Hwnd, $true) | Out-Null; Start-Sleep -Milliseconds 350 }
  $cx = [WXW]::CliX($Hwnd); $cy = [WXW]::CliY($Hwnd)
  $cw = [WXW]::CliW($Hwnd); $ch = [WXW]::CliH($Hwnd)
  $bmp = New-Object System.Drawing.Bitmap ([int]$cw), ([int]$ch)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($cx, $cy, 0, 0, $bmp.Size)
  $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose()
  if ($TopMost) { [WXW]::Top($Hwnd, $false) | Out-Null }
  Write-Output "SHOT $Path ${cw}x${ch} @ $cx,$cy"
}

# 截整个屏幕（用于排查位置）
function Save-ScreenShot {
  param([string]$Path)
  $s = Get-ScreenSize
  $bmp = New-Object System.Drawing.Bitmap ([int]$s.W), ([int]$s.H)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen(0, 0, 0, 0, $bmp.Size)
  $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose()
  Write-Output "SCREENSHOT $Path $($s.W)x$($s.H)"
}

# 客户区相对坐标点击：平滑移动 -> 悬停 -> 按下 -> 松开
# 必须先平滑移动，瞬移后立即按下会被 Qt 判为异常手势并弹出多选工具栏
function Invoke-RelClick {
  param([IntPtr]$Hwnd, [int]$RX, [int]$RY, [int]$Steps = 6, [int]$StepMs = 12, [int]$HoverMs = 80)
  $tx = [WXW]::CliX($Hwnd) + $RX
  $ty = [WXW]::CliY($Hwnd) + $RY
  $p = New-Object WXW+POINT
  [WXW]::GetCursorPos([ref]$p) | Out-Null
  $sx = $p.X; $sy = $p.Y
  for ($i = 1; $i -le $Steps; $i++) {
    $nx = [int]($sx + ($tx - $sx) * $i / $Steps)
    $ny = [int]($sy + ($ty - $sy) * $i / $Steps)
    [WXW]::SetCursorPos($nx, $ny) | Out-Null
    Start-Sleep -Milliseconds $StepMs
  }
  [WXW]::SetCursorPos($tx, $ty) | Out-Null
  Start-Sleep -Milliseconds $HoverMs
  [WXW]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 55
  [WXW]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 150
  Write-Output "CLICK rel=($RX,$RY) abs=($tx,$ty)"
}

# 键盘：CtrlV / CtrlA / Backspace / Enter / Esc / 单键
function Send-WxKey {
  param([IntPtr]$Hwnd, [ValidateSet('ctrlv','ctrla','bs','enter','esc','vk')] [string]$Kind = 'enter', [int]$VK = 0)
  Set-WeixinForeground -Hwnd $Hwnd
  switch ($Kind) {
    'ctrlv' { [WXW]::keybd_event(0x11,0,0,[UIntPtr]::Zero); [WXW]::keybd_event(0x56,0,0,[UIntPtr]::Zero); [WXW]::keybd_event(0x56,0,[WXW]::KU,[UIntPtr]::Zero); [WXW]::keybd_event(0x11,0,[WXW]::KU,[UIntPtr]::Zero) }
    'ctrla' { [WXW]::keybd_event(0x11,0,0,[UIntPtr]::Zero); [WXW]::keybd_event(0x41,0,0,[UIntPtr]::Zero); [WXW]::keybd_event(0x41,0,[WXW]::KU,[UIntPtr]::Zero); [WXW]::keybd_event(0x11,0,[WXW]::KU,[UIntPtr]::Zero) }
    'bs'    { [WXW]::keybd_event(0x08,0,0,[UIntPtr]::Zero); [WXW]::keybd_event(0x08,0,[WXW]::KU,[UIntPtr]::Zero) }
    'enter' { [WXW]::keybd_event(0x0D,0,0,[UIntPtr]::Zero); [WXW]::keybd_event(0x0D,0,[WXW]::KU,[UIntPtr]::Zero) }
    'esc'   { [WXW]::keybd_event(0x1B,0,0,[UIntPtr]::Zero); [WXW]::keybd_event(0x1B,0,[WXW]::KU,[UIntPtr]::Zero) }
    'vk'    { [WXW]::keybd_event([byte]$VK,0,0,[UIntPtr]::Zero); [WXW]::keybd_event([byte]$VK,0,[WXW]::KU,[UIntPtr]::Zero) }
  }
}
