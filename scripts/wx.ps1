param(
  [string]$action = "shot",
  [int]$x = 0, [int]$y = 0,
  [string]$text = "",
  [string]$text2 = "",
  [string]$expect = "",
  [string]$out = "a.png",
  [int]$scroll = 0,
  [switch]$all,
  [string]$min = "",
  [string]$max = "",
  [int]$rounds = 0,
  [switch]$ForceGeom
)
# 复用 win.ps1 的窗口工具库与 C# 类型（WXW），避免本脚本再编译一遍（省约 237ms）
. (Join-Path $PSScriptRoot "win.ps1")

# ============================================================
# 第一步（极速版）：一次拿到句柄 + 几何 + 全部坐标
# Start-WxReady 内部：缓存命中不枚举、位置正确零动作、只读一次外框
# ============================================================
$ctx = Start-WxReady -Force:$ForceGeom
$script:expectSig = ""
$HWND = $ctx.Hwnd
$W = $ctx.ClientW; $H = $ctx.ClientH
$CL = $ctx.ClientX; $CT = $ctx.ClientY
$SEARCH_X = $ctx.SearchX; $SEARCH_Y = $ctx.SearchY
$ROW_X    = $ctx.RowX;    $ROW_FIRST = $ctx.RowFirst; $ROW_STEP = $ctx.RowStep
$INPUT_X  = $ctx.InputX;  $INPUT_Y = $ctx.InputY

# 未读检测用：只截左侧会话栏一条窄图（310x700 约 37ms，比整屏截图快很多）
$STRIP_X = 0;  $STRIP_Y = 60; $STRIP_W = 330; $STRIP_H = 1080   # 实测列表可视区一直到客户区 y≈1140，不能只截 700
# 扫描 x 范围：真角标只贴在头像右上/左上角（实测 x 156~196）。
# 起点必须 >=145，否则会把头像本身的红色（卡通/花朵/品牌色）认成角标，
# 造成「点不掉、每轮都剩 1 个」的死循环；终点 200 避开右侧时间文字。
# 角标可能贴头像左上，也可能贴右上（SKILL.md 实测结论），扫描带必须整段盖住头像。
# 头像左边约 x=90，角标贴左上时中心在 x≈106，旧的 X0=145 把这类角标全漏掉
# （实测 count=0 但画面上有两个红点）。
$BADGE_X0 = 88; $BADGE_X1 = 200
$ROW_TOP_CLIENT = 156                 # 第一个会话行中心（客户区绝对 y，实测）
$ROW_STEP_STRIP = 89                  # 实测行高（旧值 96 已过时）
$ROW_TOP = $ROW_TOP_CLIENT - $STRIP_Y # 换成裁剪图内坐标给检测用

Write-Output ("READY screen={0}x{1} client={2}x{3}@{4},{5} fixed={6} hwnd={7}" -f `
  $ctx.ScreenW, $ctx.ScreenH, $W, $H, $CL, $CT, $ctx.Fixed, $HWND)

# PowerShell 的 Set-Clipboard 不接受空字符串（判为 null 抛异常），用 .NET 清理
function Clear-Clipboard {
  try { [System.Windows.Forms.Clipboard]::Clear() } catch {
    try { Set-Clipboard -Value " " | Out-Null } catch { }
  }
}

# 截图：客户区现取，不再置顶（几何已在第一步确认，窗口就在预期位置）
function Shot([string]$path) {
  $bmp = New-Object System.Drawing.Bitmap $W, $H
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($CL, $CT, 0, 0, $bmp.Size)
  $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose()
  Write-Output "SHOT $path"
}

# 相对客户区点击：平滑移动（避免 Qt 误判多选模式）+ 悬停稳定 + 按下松开
function ClickRel([int]$rx, [int]$ry) {
  $tx = [int]$CL + [int]$rx; $ty = [int]$CT + [int]$ry
  $sx = [IntPtr]::Zero
  $sx = [WXW]::CursorX(); $sy = [WXW]::CursorY()
  Write-Output ("CLICK rel=({0},{1}) abs=({2},{3})" -f $rx, $ry, $tx, $ty)
  for ($i = 1; $i -le 5; $i++) {
    [WXW]::SetCursorPos([int]($sx + ($tx - $sx) * $i / 5), [int]($sy + ($ty - $sy) * $i / 5)) | Out-Null
    Start-Sleep -Milliseconds 10
  }
  [WXW]::SetCursorPos($tx, $ty) | Out-Null
  Start-Sleep -Milliseconds 60
  [WXW]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 45
  [WXW]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 120
}

# ============================================================
# 未读角标检测：只截会话栏窄图 + 像素扫描，不依赖读图
# 微信 4.x 是 Qt 自绘（UIA 只有 2 个空 Pane，读不到任何文字），
# 所以未读数只能从像素上认。红点特征：圆角方形、22px 左右、纯红高填满。
# ============================================================
function ScrollList([int]$notches) {
  # 在会话列表区域滚轮。正数向下，负数向上。滚完等列表重绘。
  $sx = [int]$CL + 170; $sy = [int]$CT + 500
  [WXW]::SetCursorPos($sx, $sy) | Out-Null
  Start-Sleep -Milliseconds 40
  for ($i = 0; $i -lt [math]::Abs($notches); $i++) {
    # 实测标定（用户辅助标定）：1 次滚轮 = 半行，8 次 = 完整一屏（11 行），
    # 10 次已超出可视区，故 8 为一次完整覆盖。
    [WXW]::WheelMsg([IntPtr]$HWND, $(if ($notches -gt 0) { -120 } else { 120 }), $sx, $sy) | Out-Null
    Start-Sleep -Milliseconds 32
  }
  Start-Sleep -Milliseconds 300      # 列表滚动惯性 + 重绘
}

function Get-UnreadBadges {
  $bmp = New-Object System.Drawing.Bitmap $STRIP_W, $STRIP_H
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen([int]$CL + $STRIP_X, [int]$CT + $STRIP_Y, 0, 0,
                    (New-Object System.Drawing.Size $STRIP_W, $STRIP_H))
  $g.Dispose()

  # 逐像素扫红色，按 4px 一行归并。PS 里 HashTable 存数组改不回值，用三张独立表。
  $rowMinX = @{}; $rowMaxX = @{}; $rowCnt = @{}
  for ($yy = 0; $yy -lt $STRIP_H; $yy++) {
    for ($xx = $BADGE_X0; $xx -lt $BADGE_X1; $xx++) {
      $c = $bmp.GetPixel($xx, $yy)
      # 红判据放宽：实测这批角标是 (171,25,9)/(169,85,92)，R=171，
      # 旧的 R>190 把它们全滤掉 -> count=0 但画面有红点。
      # 保留「R 明显高于 G/B」这个本质特征，避免把灰底、绿底当红。
      if ($c.R -gt 150 -and $c.G -lt 120 -and $c.B -lt 120 -and ($c.R - $c.G) -gt 80 -and ($c.R - $c.B) -gt 60) {
        $k = $yy / 4
        if (-not $rowCnt.ContainsKey($k)) { $rowMinX[$k] = $xx; $rowMaxX[$k] = $xx; $rowCnt[$k] = 1 }
        else {
          if ($xx -lt $rowMinX[$k]) { $rowMinX[$k] = $xx }
          if ($xx -gt $rowMaxX[$k]) { $rowMaxX[$k] = $xx }
          $rowCnt[$k] = $rowCnt[$k] + 1
        }
      }
    }
  }
  $bmp.Dispose()

  # 相邻行归并成块
  $script:res = @()
  $bStart = -1; $bEnd = -1; $bx0 = 9999; $bx1 = -1; $bcnt = 0; $prev = -99
  $flush = {
    if ($bStart -lt 0) { return }
    $y0 = $bStart * 4; $y1 = $bEnd * 4 + 3
    $wv = $bx1 - $bx0 + 1; $hv = $y1 - $y0 + 1
    $fill = $bcnt / [double]($wv * $hv)
    # 只留近似方形、填充率过半、尺寸像角标（15~34px）的块，滤掉红色文字
    # 实测区分真角标 vs 误报：
      #   真角标 12~22px 方形 fill>=0.66，位置在头像右上/左上（x 156~196）
      #   误报是群摘要里的红字「[5条]」，9px 小块 fill 0.67 / 长条 fill 0.29~0.30
      # 所以要求：正方形 + fill>=0.62 + 边长>=11
      if ([math]::Abs($wv - $hv) -le 4 -and $fill -ge 0.62 -and $wv -ge 11 -and $wv -le 34) {
      $cy = [int](($y0 + $y1) / 2)
      $script:res = @($script:res) + [pscustomobject]@{
        Row  = [int][math]::Round(($cy - $ROW_TOP) / [double]$ROW_STEP_STRIP)
        CY   = $cy
        AbsY = $cy + $STRIP_Y
        CX   = [int](($bx0 + $bx1) / 2)
        Size = $wv
        Fill = [math]::Round($fill, 2)
      }
    }
  }
  foreach ($k in ($rowCnt.Keys | Sort-Object)) {
    if ($bStart -lt 0 -or ($k - $prev) -gt 1) {
      & $flush
      $bStart = $k; $bEnd = $k; $bx0 = $rowMinX[$k]; $bx1 = $rowMaxX[$k]; $bcnt = $rowCnt[$k]
    }
    else {
      $bEnd = $k
      if ($rowMinX[$k] -lt $bx0) { $bx0 = $rowMinX[$k] }
      if ($rowMaxX[$k] -gt $bx1) { $bx1 = $rowMaxX[$k] }
      $bcnt += $rowCnt[$k]
    }
    $prev = $k
  }
  & $flush

  return $res
}

function FocusWnd() {
  if ([WXW]::GetForegroundWindow() -ne $HWND) {
    [WXW]::SetForegroundWindow($HWND) | Out-Null
    Start-Sleep -Milliseconds 120
  }
}

function ClearBox() {
  Clear-Clipboard
  [WXW]::CtrlA()
  [WXW]::Bs()
  [WXW]::Bs()
  Start-Sleep -Milliseconds 80
}

# ============================================================
# 互聊支持：一次进程内跑多轮，不在外面反复起进程
# ============================================================

# 取聊天区底部一块画面的指纹（只看有没有新气泡，不看具体字）
# 聊天区 x 从约 460 起，底部消息区 y 约 900~1140
function Get-BottomSig {
  # 覆盖整个聊天消息区（标题栏下方 ~ 输入框上方），不只看底部一小块
  # 采样 8px、量化 16 档：小字消息和「正在输入」提示都能分辨出来
  $bw = 700; $bh = 780
  $bx = [int]$CL + 430; $by = [int]$CT + 110
  $bmp = New-Object System.Drawing.Bitmap $bw, $bh
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($bx, $by, 0, 0, $bmp.Size)
  $sb = New-Object System.Text.StringBuilder
  for ($yy = 4; $yy -lt $bh; $yy += 8) {
    for ($xx = 4; $xx -lt $bw; $xx += 8) {
      $c = $bmp.GetPixel($xx, $yy)
      $v = [int](($c.R + $c.G + $c.B) / 3)
      $q = [int]($v / 16)
      [void]$sb.Append([char](48 + $q))
    }
  }
  $g.Dispose(); $bmp.Dispose()
  return $sb.ToString()
}

function Get-PeerSig {
  # 判定「聊天区最底部那一条消息是谁发的」
  #   从消息区底往上扫，找第一条连续非背景带（灰气泡 47,47,48 或 绿气泡 53,210,141）
  #   再数这条带里 灰点多 还是 绿点多 -> PEER / SELF
  #   实测: 23~62ms，与滚动位置无关
  # 只扫气泡所在的横带：客户区 x 380~900。
  # 左侧 0~380 是会话列表和联系人头像，头像图片里有大量中性灰，会把
  # 相邻两条气泡连成一条带（实测 h 从 54 涨到 214），必须排除。
  $bx = [int]$CL + 380; $by = [int]$CT + 120
  $bw = 520; $bh = 800
  $bmp = New-Object System.Drawing.Bitmap $bw, $bh
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($bx, $by, 0, 0, $bmp.Size)
  $bandBot = -1; $bandH = 0
  $inrun = $false; $rs = 0
  for ($yy = $bh - 2; $yy -ge 2; $yy -= 2) {
    $n = 0
    for ($xx = 2; $xx -lt $bw; $xx += 8) {
      $c = $bmp.GetPixel($xx, $yy)
      $isGray = (($c.R -ge 45) -and ($c.R -le 51) -and ([Math]::Abs($c.R - $c.G) -le 1) -and ($c.B -ge 45) -and ($c.B -le 53))
      $isGrn = (($c.G -gt 150) -and (($c.G - $c.R) -gt 80) -and (($c.G - $c.B) -gt 40))
      if ($isGray -or $isGrn) { $n++ }
    }
    if ($n -ge 10) {
      if (-not $inrun) { $rs = $yy; $inrun = $true }
    } else {
      if ($inrun) { $bandBot = $yy; $bandH = $rs - $yy; break }
    }
  }
  if ($inrun -and $bandBot -lt 0) { $bandBot = 2; $bandH = $rs - 2 }
  $gr = 0; $gy = 0
  if ($bandBot -ge 0 -and $bandH -ge 20) {
    for ($yy = $bandBot + 2; $yy -lt ($bandBot + $bandH - 2); $yy += 4) {
      for ($xx = 2; $xx -lt $bw; $xx += 8) {
        $c = $bmp.GetPixel($xx, $yy)
        if (($c.G -gt 150) -and (($c.G - $c.R) -gt 80) -and (($c.G - $c.B) -gt 40)) { $gr++ }
        elseif (($c.R -ge 45) -and ($c.R -le 51) -and ([Math]::Abs($c.R - $c.G) -le 1) -and ($c.B -ge 45) -and ($c.B -le 53)) { $gy++ }
      }
    }
  }
  $g.Dispose(); $bmp.Dispose()
  $who = if ($gr -gt $gy) { "SELF" } else { "PEER" }
  return "$who`:bot=$bandBot,h=$bandH,grn=$gr,gry=$gy"
}

function Get-SigDiff([string]$a, [string]$b) {
  # 返回两张指纹的不同点数（实测：静止噪声 5~9；对方回复 2000+）
  $n = [Math]::Min($a.Length, $b.Length)
  $d = 0
  for ($i = 0; $i -lt $n; $i++) { if ($a[$i] -ne $b[$i]) { $d++ } }
  if ($a.Length -ne $b.Length) { $d += [Math]::Abs($a.Length - $b.Length) }
  return $d
}
# 判定阈值：大于此值才算「画面真的变了」（远大于噪声 9，远小于对方回复 2828）
$SIG_THRESH = 100

function Get-TitleSig {
  # 只拍会话标题（客户区右上聊天区顶部），用来校验「当前打开的会话是谁」
  # 标题栏文字区：客户区 x 实测标题在 (478,83) 附近，取 300x46
  $bw = 300; $bh = 46
  $bx = [int]$CL + 460; $by = [int]$CT + 60
  $bmp = New-Object System.Drawing.Bitmap $bw, $bh
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($bx, $by, 0, 0, $bmp.Size)
  $sb = New-Object System.Text.StringBuilder
  for ($yy = 2; $yy -lt $bh; $yy += 4) {
    for ($xx = 2; $xx -lt $bw; $xx += 4) {
      $c = $bmp.GetPixel($xx, $yy)
      $v = [int](($c.R + $c.G + $c.B) / 3)
      $q = [int]($v / 16)
      [void]$sb.Append([char](48 + $q))
    }
  }
  $g.Dispose(); $bmp.Dispose()
  return $sb.ToString()
}

# 发一条：清空 -> 粘贴 -> 回车（不再截图，省时间；调用方需要时自己 Shot）
function SendText([string]$body) {
  FocusWnd
  ClearBox
  Set-Clipboard -Value $body | Out-Null
  [WXW]::CtrlV()
  Start-Sleep -Milliseconds 260
  [WXW]::Enter()
  Start-Sleep -Milliseconds 380
}

if ($action -eq "shot") {
  Shot $out
}
elseif ($action -eq "click") {
  ClickRel $x $y
  Shot $out
}
elseif ($action -eq "paste") {
  FocusWnd
  Set-Clipboard -Value $text | Out-Null
  [WXW]::CtrlV()
  Start-Sleep -Milliseconds 350
  Shot $out
}
elseif ($action -eq "clear") {
  ClearBox
  Shot $out
}
elseif ($action -eq "enter") {
  FocusWnd
  [WXW]::Enter()
  Start-Sleep -Milliseconds 400
  Shot $out
}
elseif ($action -eq "key") {
  FocusWnd
  [WXW]::KeyDown($x); Start-Sleep -Milliseconds 60; [WXW]::KeyUp($x)
  Start-Sleep -Milliseconds 400
  Shot $out
}
elseif ($action -eq "esc") {
  FocusWnd
  [WXW]::Esc()
  Start-Sleep -Milliseconds 300
  Shot $out
}
elseif ($action -eq "go") {
  # 一次完成：点搜索框 -> 粘贴关键词 -> 点联系人 -> 点输入区。只在结束截图。
  # 「点联系人」坐标已修正：搜索面板里「联系人」分组的第一行在客户区 y≈200
  # （旧值 270 是面板下半部的群聊/聊天记录区，点了会进错会话或落到会话列表上）
  $rowY = if ($y -gt 0) { $y } else { 200 }
  ClickRel $SEARCH_X $SEARCH_Y
  Start-Sleep -Milliseconds 220      # 搜索面板弹出
  Set-Clipboard -Value $text | Out-Null
  [WXW]::CtrlV()
  Start-Sleep -Milliseconds 480      # 结果列表渲染（不可再压，会点空）
  ClickRel $ROW_X $rowY
  Start-Sleep -Milliseconds 200      # 会话切换
  ClickRel $INPUT_X $INPUT_Y
  Start-Sleep -Milliseconds 100
  # 记录该联系人的标题指纹：go 进对了人，chat -expect 才有可信基线可比
  if ($text -ne "") {
    $curTitle = Get-TitleSig
    $sigHash = ([BitConverter]::ToString([Security.Cryptography.MD5]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace("-", "").Substring(0, 8).ToLower()
    $curTitle | Out-File -Encoding ascii -NoNewline (Join-Path $PSScriptRoot ("expect_" + $sigHash + ".sig"))
    Write-Output ("GO titlebase=[{0}] sig={1}" -f $text, $curTitle)
  }
  Shot $out
}
elseif ($action -eq "send") {
  FocusWnd
  # 一次完成：清空 -> 粘贴 -> 回车 -> 结果图。中间不截图。
  ClearBox
  Set-Clipboard -Value $text | Out-Null
  [WXW]::CtrlV()
  Start-Sleep -Milliseconds 260      # 粘贴落地
  [WXW]::Enter()
  Start-Sleep -Milliseconds 380      # 气泡出现
  Shot $out
}
elseif ($action -eq "chat") {
  # ============================================================
  # 互动模式：一次进程内完成「发送 -> 定时截图 -> 发现对方回复 -> 交给外部生成下一句」
  # 语义：-text 是本轮要发的内容；-min/-max 是等对方回复的秒数区间；
  #       到点就截图并判定对方有没有回，不再由外部一步步催。
  # 不做「耗时超时就报错」——发送成功就是成功。
  # ============================================================
  # ============================================================
  # 交互式：发完立即返回，不等。等待对方回复用 -action wait
  # 指纹用 Get-PeerSig（只拍左侧竖条，只含对方消息，自己的气泡进不来）
  # ============================================================
  $swAll = [System.Diagnostics.Stopwatch]::StartNew()
  $sent  = @()

  # 会话校验：-expect 指定时确认当前会话就是目标人，防止切换后发错
  # 基线落在 expect_<hash>.sig（由 -action go 写入）。标题指纹逐像素取，
  # 同一会话稳定、换人必变，所以比对是硬判据，不是「首次恒通过」。
  if ($expect -ne "") {
    $curTitle = Get-TitleSig
    $sigHash = ([BitConverter]::ToString([Security.Cryptography.MD5]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($expect)))).Replace("-", "").Substring(0, 8).ToLower()
    $sigFile = Join-Path $PSScriptRoot ("expect_" + $sigHash + ".sig")
    if (Test-Path $sigFile) {
      $baseTitle = (Get-Content $sigFile -Raw).Trim()
      if ($curTitle -ne $baseTitle) {
        Write-Output "CHAT ABORT :: 当前窗口不是 [$expect]，拒绝发送"
        return
      }
      Write-Output "CHAT expect=[$expect] titleOK"
    } else {
      $curTitle | Out-File -Encoding ascii -NoNewline $sigFile
      Write-Output "CHAT expect=[$expect] titleNOBASE :: 首次记录标题指纹，本轮未比对，必须看截图确认人对了"
    }
  }

  # 发送前取基线，落盘 peersig_base.txt 供排查
  $baseSig = Get-PeerSig
  $sigFile = Join-Path $PSScriptRoot "peersig_base.txt"
  $baseSig | Out-File -Encoding ascii -NoNewline $sigFile

  if ($text -ne "") {
    foreach ($seg in ($text -split '\|')) {
      $seg = $seg.Trim()
      if ($seg -eq "") { continue }
      SendText $seg
      $sent += $seg
      Write-Output ("CHAT sent [{0}] cost={1}ms :: {2}" -f $sent.Count, $swAll.ElapsedMilliseconds, $seg)
      Start-Sleep -Milliseconds 300
    }
  }

  # 发完立刻返回。若传了 -min/-max，则顺带在进程内等一小会（默认 0）
  $wait1 = 0
  if ($min -ne "" -and $text -ne "") {
    $mn = [int]([double]$min * 1000)
    $mx = [int]([double]$max * 1000)
    if ($mx -le $mn) { $mx = $mn + 1000 }
    $wait1 = Get-Random -Minimum $mn -Maximum ($mx + 1)
  }
  # 发送后状态：此时最后一条必然是我方绿气泡 -> SELF。
  # 这才是「联系人是否新回复」的参照物。发完不回 SELF 说明判定退化了，直接报出来。
  $afterSig = ""
  if ($text -ne "") {
    Start-Sleep -Milliseconds 260
    $afterSig = Get-PeerSig
    $afterSig | Out-File -Encoding ascii -NoNewline (Join-Path $PSScriptRoot "peersig_after.txt")
    Write-Output ("CHAT after={0}" -f $afterSig)
  }
  $afterWho = if ($afterSig -like "SELF:*") { "SELF" } elseif ($afterSig -like "PEER:*") { "PEER" } else { "" }
  if ($text -ne "" -and $afterWho -eq "PEER") {
    Write-Output "CHAT WARN :: 发完仍判 PEER，判定可能退化，本轮 wait 要按画面变化判定"
  }

  $peer = $false
  $waited = 0
  if ($wait1 -gt 0) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $wait1) {
      Start-Sleep -Milliseconds 500
      $nowSig = Get-PeerSig
      $hit = $false
      if ($nowSig -like "PEER:*") {
        if ($afterWho -eq "SELF") { $hit = $true }
        elseif ($afterWho -eq "PEER" -and $nowSig -ne $afterSig) { $hit = $true }
      }
      if ($hit) { $peer = $true; $df = $nowSig; break }
    }
    $waited = $sw.ElapsedMilliseconds
  }

  if ($text -ne "") {
    Write-Output ("CHAT DO sent={0} peer={1} waited={2}ms total={3}ms" -f $sent.Count, $peer, $waited, $swAll.ElapsedMilliseconds)
  } else {
    Write-Output ("CHAT DO sent=0 total={0}ms" -f $swAll.ElapsedMilliseconds)
  }
  if ($peer) { Write-Output "CHAT PEER_REPLIED" }
}
elseif ($action -eq "wait") {
  # ============================================================
  # 只等不发：轮询左侧竖条指纹，一旦变化（对方回复）立刻截图返回
  #   -min/-max : 最多等多少秒（默认 30~30）
  #   -base     : 可选，外部传入的上一次基线；不传则用当前画面作为基线
  # ============================================================
  $mn = if ($min -ne "") { [int]([double]$min * 1000) } else { 30000 }
  $mx = if ($max -ne "") { [int]([double]$max * 1000) } else { $mn }
  if ($mx -lt $mn) { $mx = $mn }
  $limit = Get-Random -Minimum $mn -Maximum ($mx + 1)
  # 基线 = chat 发送完成后的画面状态（理应 SELF）。用它当参照物，
  # 否则「基线本来就是 PEER」会被当成立刻回复，变成自己跟自己聊。
  $afterFile = Join-Path $PSScriptRoot "peersig_after.txt"
  $baseFile  = Join-Path $PSScriptRoot "peersig_base.txt"
  if (Test-Path $afterFile) {
    $baseSig = (Get-Content $afterFile -Raw).Trim()
    $src = "after"
  } elseif (Test-Path $baseFile) {
    $baseSig = (Get-Content $baseFile -Raw).Trim()
    $src = "base"
  } else {
    $baseSig = Get-PeerSig
    $src = "live"
  }
  $baseWho = if ($baseSig -like "SELF:*") { "SELF" } elseif ($baseSig -like "PEER:*") { "PEER" } else { "NONE" }
  Write-Output ("WAIT base_src={0} base={1}" -f $src, $baseSig)
  if ($baseWho -eq "PEER") {
    Write-Output "WAIT WARN :: 基线是 PEER（发送后判定退化），本轮只认画面变化，不认 PEER 状态"
  }
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $peer = $false
  $ticks = 0
  $df = 0
  while ($sw.ElapsedMilliseconds -lt $limit) {
    Start-Sleep -Milliseconds 500
    $ticks++
    $nowSig = Get-PeerSig
    $hit = $false
    if ($nowSig -like "PEER:*") {
      if ($baseWho -eq "SELF") { $hit = $true }
      elseif ($baseWho -eq "PEER" -and $nowSig -ne $baseSig) { $hit = $true }
    }
    if ($hit) { $peer = $true; $df = $nowSig; break }
  }
  Shot $out
  Write-Output ("WAIT peer={0} ticks={1} waited={2}ms of {3}ms now={4}" -f `
    $peer, $ticks, $sw.ElapsedMilliseconds, $limit, $df)
  if ($peer) { Write-Output "WAIT PEER_REPLIED" } else { Write-Output "WAIT NO_REPLY" }
}

elseif ($action -eq "unread" -or $action -eq "read" -or $action -eq "readall") {
  # -scroll N：当前屏没找到就向下滚，最多翻 N 轮（1 轮 = 8 次滚轮 = 完整一屏）
  # unread  = 只报告当前屏（可滚 N 轮找）
  # read    = 命中第一个未读就点开，不继续滚
  # readall = 逐屏向下扫，把沿途每个未读都点开，最多滚 N 轮（默认 5）
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $want = if (-not $PSBoundParameters.ContainsKey('scroll')) { 0 } else { $scroll }
  # 实测标定：8 次滚轮 = 完整一屏；默认最多扫 5 轮 = 40 次，再往下不看
  $steps = @(8,8,8,8,8)
  $found = @()
  $pass = 0
  while ($true) {
    $found = @(Get-UnreadBadges)
    if ($found.Count -gt 0) { break }
    if ($pass -ge $want) { break }
    ScrollList $steps[[math]::Min($pass, $steps.Count - 1)]
    $pass++
  }
  $ms = $sw.ElapsedMilliseconds

  if ($action -eq "unread") {
    Write-Output ("UNREAD count={0} cost={1}ms scrolls={2}" -f $found.Count, $ms, $pass)
    $i = 0
    foreach ($b in $found) {
      Write-Output ("  #{0} row={1} size={2} fill={3} -> 客户区点击点 (300,{4})" -f `
        $i, $b.Row, $b.Size, $b.Fill, $b.AbsY)
      $i++
    }
    Shot $out
  }
  elseif ($action -eq "readall") {
    # 逐屏向下扫，把沿途每个未读都点开（只已读，不发消息）
    # 全量清理 = -all：不限轮数，一直滚到列表底（连续 2 轮画面无变化即到底）
    $full = [bool]$all
    $rounds = if ($full) { 200 } elseif ($want -gt 0) { $want } else { 5 }
    $clicked = 0
    $seenY = @()
    $script:lastSig = ""; $script:stillCnt = 0; $script:badY = @()
    if ($full) {
      # 全量清理必须先回到列表顶部，否则会漏掉上面没读的
      Write-Output "FULL reset to top..."
      ScrollList -40
      Start-Sleep -Milliseconds 500
    }
    for ($r = 0; $r -le $rounds; $r++) {
      $cur = @(Get-UnreadBadges) | Where-Object { -not ($script:badY -contains $_.AbsY) }
      Write-Output ("PASS {0} badges={1}" -f $r, @($cur).Count)
      if (@($cur).Count -gt 0) {
        foreach ($b in ($cur | Sort-Object AbsY)) {
          # 同一 y 只点一次，防止点完不消失导致死循环
          if ($seenY -contains $b.AbsY) { continue }
          # 黑名单：点过但没消失的位置（头像自带红色块误报），直接跳过不再重试
          if ($script:badY -contains $b.AbsY) { continue }
          ClickRel 300 $b.AbsY
          Start-Sleep -Milliseconds 300
          $seenY += $b.AbsY
          $clicked++
          # 点完立刻复检：这一行角标还在 = 不是未读（头像自带红色块），拉黑
          $chk = @(Get-UnreadBadges) | Where-Object { [math]::Abs($_.AbsY - $b.AbsY) -le 6 }
          if (@($chk).Count -gt 0) { $script:badY += $b.AbsY; Write-Output ("  SKIP y={0} 非未读(点不掉,已拉黑)" -f $b.AbsY) }
          else { Write-Output ("  CLICK y={0} size={1} -> clicked={2}" -f $b.AbsY, $b.Size, $clicked) }
        }
        # 点完这一屏重新检测，确认清干净再滚（黑名单里的误报不算）
        $left = @(Get-UnreadBadges) | Where-Object { -not ($script:badY -contains $_.AbsY) }
        $leftN = @($left).Count
        Write-Output ("  PASS {0} left={1}" -f $r, $leftN)
        if ($leftN -gt 0) { continue }
      }
      if ($r -eq $rounds) { break }
      if ($full) {
        # 到底判定：整屏指纹比对，连续 2 轮完全不变化 = 已到底
        $bmpF = New-Object System.Drawing.Bitmap 330, 1000
        $gF = [System.Drawing.Graphics]::FromImage($bmpF)
        $gF.CopyFromScreen([int]$CL + 0, [int]$CT + 100, 0, 0, (New-Object System.Drawing.Size 330, 1000))
        $gF.Dispose()
        $sb = New-Object System.Text.StringBuilder
        for ($yy = 0; $yy -lt 1000; $yy += 6) {
          for ($xx = 0; $xx -lt 330; $xx += 6) {
            $c = $bmpF.GetPixel($xx, $yy)
            [void]$sb.Append([char](48 + (($c.R + $c.G + $c.B) % 40)))
          }
        }
        $bmpF.Dispose()
        $curSig = $sb.ToString()
        if ($script:lastSig -eq $curSig) { $script:stillCnt++; } else { $script:stillCnt = 0 }
        $script:lastSig = $curSig
        if ($script:stillCnt -ge 2) {
          Write-Output ("  REACHED BOTTOM at round {0}" -f $r)
          break
        }
      }
      ScrollList 8
    }
    Write-Output ("READALL done clicked={0} rounds={1} full={2} cost={3}ms" -f $clicked, $r, $full, $sw.ElapsedMilliseconds)
    Shot $out
  }
  else {
    if ($found.Count -eq 0) {
      Write-Output ("READ none 翻了 {0} 次仍没有未读会话 cost={1}ms" -f $pass, $ms)
      Shot $out
    }
    else {
      # 第一个未读 = 当前屏最靠上的那个
      # 第一个未读 = 当前屏最靠上的那个（按红点实际 y 排）
      $b = $found | Sort-Object AbsY | Select-Object -First 1
      # 红点垂直中心基本落在行中心上（实测偏差 <30px），直接点该行
      $clickY = $b.AbsY
      Write-Output ("READ pick=first size={0} fill={1} clickX=300 clickY={2} scrolls={3}" -f `
        $b.Size, $b.Fill, $clickY, $pass)
      ClickRel 300 $clickY
      Start-Sleep -Milliseconds 320
      $after = @(Get-UnreadBadges)
      Write-Output ("READ done before={0} after={1} cost={2}ms" -f $found.Count, $after.Count, $sw.ElapsedMilliseconds)
      Shot $out
    }
  }
}
else {
  Write-Output "ERR unknown action: $action"
  exit 1
}

# 恢复窗口普通层级
[WXW]::SetWindowPos($HWND, [IntPtr](-2), 0, 0, 0, 0, 0x0003) | Out-Null