# 补丁解析与内容级匹配的公共函数库
# 被 apply-patches 与 verify-patch-effect 两个 composite action 共同引用。
#
# 存在的原因：git 的上下文匹配（git apply）在上游改动同一文件的邻近行时会失败，
# 而反向检查（git apply --reverse）同样依赖上下文，会把「效果仍在」误判成「效果消失」。
# 因此这里全部改用**与上下文无关**的内容级判定：
#   补丁的新增行必须在文件里出现，被删除的行必须不再出现。

function Get-PatchFiles {
    <#
      解析一个 .patch 文件，返回文件列表：
        @{ Path = '相对路径'; Hunks = @( @{ Removed = @(); Added = @() } ) }
      每个 hunk 的 Removed / Added 是「连续行块」。
    #>
    param([string]$Path)

    $lines = [System.IO.File]::ReadAllText($Path) -split "`r?`n"
    $files = [System.Collections.Generic.List[object]]::new()
    $hunks = [System.Collections.Generic.List[object]]::new()
    $removed = [System.Collections.Generic.List[string]]::new()
    $added = [System.Collections.Generic.List[string]]::new()
    $curPath = $null
    $inHunk = $false

    foreach ($ln in $lines) {
        if ($ln.StartsWith('diff --git ')) {
            if ($curPath) { $files.Add(@{ Path = $curPath; Hunks = $hunks }) }
            $m = [regex]::Match($ln, '^diff --git a/(.+?) b/(.+)$')
            $curPath = if ($m.Success) { $m.Groups[2].Value } else { $null }
            $hunks = [System.Collections.Generic.List[object]]::new()
            $removed = [System.Collections.Generic.List[string]]::new()
            $added = [System.Collections.Generic.List[string]]::new()
            $inHunk = $false
            continue
        }
        if ($ln.StartsWith('@@')) {
            if ($inHunk) {
                $hunks.Add(@{ Removed = @($removed); Added = @($added) })
                $removed = [System.Collections.Generic.List[string]]::new()
                $added = [System.Collections.Generic.List[string]]::new()
            }
            $inHunk = $true
            continue
        }
        if (-not $inHunk) { continue }
        if ($ln.StartsWith('--- ') -or $ln.StartsWith('+++ ')) { continue }
        if ($ln.StartsWith('-')) { $removed.Add($ln.Substring(1)) }
        elseif ($ln.StartsWith('+')) { $added.Add($ln.Substring(1)) }
        elseif ($ln.StartsWith(' ') -or $ln -eq '') { }
        else {
            $hunks.Add(@{ Removed = @($removed); Added = @($added) })
            $removed = [System.Collections.Generic.List[string]]::new()
            $added = [System.Collections.Generic.List[string]]::new()
            $inHunk = $false
        }
    }
    if ($inHunk) { $hunks.Add(@{ Removed = @($removed); Added = @($added) }) }
    if ($curPath) { $files.Add(@{ Path = $curPath; Hunks = $hunks }) }
    return $files
}

function Get-SourcePatches {
    <# 收集 .patches/ 与 patches/ 下的源码 diff 补丁（跳过上游的二进制发布包） #>
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($dir in @('.patches', 'patches')) {
        if (-not (Test-Path $dir)) { continue }
        foreach ($f in (Get-ChildItem $dir -Filter '*.patch' -File)) {
            $fs = [System.IO.File]::OpenRead($f.FullName)
            try {
                $buf = New-Object byte[] 16
                $read = $fs.Read($buf, 0, 16)
            } finally { $fs.Dispose() }
            if ([System.Text.Encoding]::ASCII.GetString($buf, 0, $read).StartsWith('diff --git')) {
                $out.Add($f)
            } else {
                Write-Host "==> 跳过 $($f.Name)（二进制补丁，非源码 diff）"
            }
        }
    }
    return @($out | Sort-Object Name)
}

function Get-FileLines {
    <# 读文件并按行返回（去掉行尾 \r），同时记录 BOM 与换行风格 #>
    param([string]$Path)
    $raw = [System.IO.File]::ReadAllBytes($Path)
    $hasBom = $raw.Length -ge 3 -and $raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF
    $content = [System.IO.File]::ReadAllText($Path)
    $nl = if ($content.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($l in ($content -split "`r?`n")) { $lines.Add($l.TrimEnd("`r")) }
    return @{ Lines = $lines; Newline = $nl; HasBom = $hasBom }
}

function Set-FileLines {
    <# 按行写回，保持原有 BOM 与换行风格 #>
    param([string]$Path, $Lines, [string]$Newline, [bool]$HasBom)
    $enc = New-Object System.Text.UTF8Encoding($HasBom)
    [System.IO.File]::WriteAllText($Path, (($Lines -join $Newline)), $enc)
}

function Find-Block {
    <# 在行集合中查找行块，返回 @{ Count; Index } #>
    param($Lines, [string[]]$Block)
    if ($Block.Count -eq 0) { return @{ Count = 0; Index = -1 } }
    $count = 0
    $index = -1
    for ($i = 0; $i -le $Lines.Count - $Block.Count; $i++) {
        $ok = $true
        for ($j = 0; $j -lt $Block.Count; $j++) {
            if ($Lines[$i + $j] -cne $Block[$j]) { $ok = $false; break }
        }
        if ($ok) { $count++; $index = $i }
    }
    return @{ Count = $count; Index = $index }
}

function Test-PatchEffect {
    <#
      上下文无关地判断补丁效果是否在文件里：
        新增行块必须恰好出现一次
        被删除行块必须一次都不再出现（纯新增的补丁没有删除块，跳过）
      返回 $true / $false
    #>
    param([string]$Path, $Hunks)
    if (-not (Test-Path $Path)) { return $false }
    $info = Get-FileLines $Path
    foreach ($h in $Hunks) {
        if ($h.Added.Count -gt 0) {
            $a = Find-Block $info.Lines $h.Added
            if ($a.Count -ne 1) { return $false }
        }
        if ($h.Removed.Count -gt 0) {
            $r = Find-Block $info.Lines $h.Removed
            if ($r.Count -ne 0) { return $false }
        }
    }
    return $true
}

function Invoke-ContentFallback {
    <#
      内容级兜底：不看上下文，按「补丁要删掉的那几行」精确定位替换。
      前提是那段被删的行在文件里有且仅有一处，否则不敢改，直接返回 $false。
    #>
    param([string]$Path, $Hunks)
    if (-not (Test-Path $Path)) { return $false }
    $info = Get-FileLines $Path
    $lines = $info.Lines
    foreach ($h in $Hunks) {
        if ($h.Removed.Count -eq 0) { continue }
        $hit = Find-Block $lines $h.Removed
        if ($hit.Count -ne 1) {
            Write-Host "    内容级兜底放弃：被删行块匹配 $($hit.Count) 处（需要恰好 1 处）"
            return $false
        }
        $lines.RemoveRange($hit.Index, $h.Removed.Count)
        $lines.InsertRange($hit.Index, [string[]]$h.Added)
    }
    Set-FileLines $Path $lines $info.Newline $info.HasBom
    return $true
}
