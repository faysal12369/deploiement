# Encodes still images into an MP4 with Windows' own encoder (WinRT MediaComposition, H.264). Windows PowerShell 5.1.
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
$null = [Windows.Storage.StorageFolder, Windows.Storage, ContentType = WindowsRuntime]
$null = [Windows.Media.Editing.MediaComposition, Windows.Media.Editing, ContentType = WindowsRuntime]
$null = [Windows.Media.Editing.MediaClip, Windows.Media.Editing, ContentType = WindowsRuntime]
$null = [Windows.Media.Editing.BackgroundAudioTrack, Windows.Media.Editing, ContentType = WindowsRuntime]
$null = [Windows.Media.MediaProperties.AudioEncodingProperties, Windows.Media.MediaProperties, ContentType = WindowsRuntime]
$null = [Windows.Media.MediaProperties.MediaEncodingProfile, Windows.Media.MediaProperties, ContentType = WindowsRuntime]
$null = [Windows.Media.Transcoding.TranscodeFailureReason, Windows.Media.Transcoding, ContentType = WindowsRuntime]

$script:asTaskOp = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
$script:asTaskProg = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperationWithProgress`2' })[0]

function Await($op, [Type]$type) {
  $t = $script:asTaskOp.MakeGenericMethod($type).Invoke($null, @($op))
  $t.Wait(-1) | Out-Null
  $t.Result
}

# $clips: list of @{ path = 'C:\..png'; seconds = 1.5 }; $music: optional WAV played under the whole video
function New-Mp4($clips, [string]$outPath, [string]$music = '') {
  $comp = New-Object Windows.Media.Editing.MediaComposition
  $add = [System.Collections.Generic.ICollection[Windows.Media.Editing.MediaClip]].GetMethod('Add')
  foreach ($c in $clips) {
    $file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($c.path)) ([Windows.Storage.StorageFile])
    $clip = Await ([Windows.Media.Editing.MediaClip]::CreateFromImageFileAsync($file, [TimeSpan]::FromSeconds($c.seconds))) ([Windows.Media.Editing.MediaClip])
    $null = $add.Invoke($comp.Clips, @($clip))
  }
  if ($music) {
    $af = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($music)) ([Windows.Storage.StorageFile])
    $bg = Await ([Windows.Media.Editing.BackgroundAudioTrack]::CreateFromFileAsync($af)) ([Windows.Media.Editing.BackgroundAudioTrack])
    $addA = [System.Collections.Generic.ICollection[Windows.Media.Editing.BackgroundAudioTrack]].GetMethod('Add')
    $null = $addA.Invoke($comp.BackgroundAudioTracks, @($bg))
  }
  $dir = Split-Path $outPath -Parent
  $name = Split-Path $outPath -Leaf
  $folder = Await ([Windows.Storage.StorageFolder]::GetFolderFromPathAsync($dir)) ([Windows.Storage.StorageFolder])
  $out = Await ($folder.CreateFileAsync($name, [Windows.Storage.CreationCollisionOption]::ReplaceExisting)) ([Windows.Storage.StorageFile])
  $profile = [Windows.Media.MediaProperties.MediaEncodingProfile]::CreateMp4([Windows.Media.MediaProperties.VideoEncodingQuality]::HD1080p)
  if ($music) { $profile.Audio = [Windows.Media.MediaProperties.AudioEncodingProperties]::CreateAac(44100, 2, 160000) } else { $profile.Audio = $null }
  $profile.Video.Bitrate = $(if ($script:Bitrate) { $script:Bitrate } else { 2500000 })   # screen content: 1.2 Mbit/s keeps it sharp and light
  $op = $comp.RenderToFileAsync($out, [Windows.Media.Editing.MediaTrimmingPreference]::Precise, $profile)
  $t = $script:asTaskProg.MakeGenericMethod([Windows.Media.Transcoding.TranscodeFailureReason], [double]).Invoke($null, @($op))
  $t.Wait(-1) | Out-Null
  $t.Result
}
