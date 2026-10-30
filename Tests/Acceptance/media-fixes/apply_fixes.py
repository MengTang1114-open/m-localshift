from pathlib import Path
p=Path('Sources/AdvancedMedia.swift');s=p.read_text()
s=s.replace('private struct LSMMediaInfo {','''private struct LSMAudioTrack {
    var channels:Int
    var language:String
    var title:String
    var disposition:String
}
private struct LSMMediaInfo {''',1)
s=s.replace('var isStillGIF:Bool;var isGIF:Bool','var isStillGIF:Bool;var isGIF:Bool;var sampleAspectRatio:Double;var audioTracks:[LSMAudioTrack]')
s=s.replace('''            if settings.exactSize {videoFilter.append("scale=\\(even(settings.width)):\\(even(settings.height))")}''','''            if settings.exactSize {videoFilter.append("scale=\\(even(settings.width)):\\(even(settings.height)),setsar=1")}''')
s=s.replace('''videoFilter.append("scale=trunc(iw/2)*2:trunc(ih/2)*2,setsar=1")''','''videoFilter.append("scale=trunc(iw/2)*2:trunc(ih/2)*2")''')
s=s.replace('''        if let graph=complex {args += ["-filter_complex",graph]}''','''        audioMap=needsVideo ? "0:a":"0:a:0"
        if let graph=complex {args += ["-filter_complex",graph]}''',1)
s=s.replace('''            let chain=videoFilter.joined(separator:",")+",fps=15,''','''            let chain=(videoFilter+[squarePixels]).joined(separator:",")+",fps=15,''')
s=s.replace('''        args += ["-map_metadata","-1",output.path]
        try run(ff,args,context:context);try validate(output,video:needsVideo,audio:needsAudio,context:context)''','''        if needsAudio,needsVideo {args += audioMetadata(info.audioTracks)}
        args += ["-map_metadata","-1",output.path]
        try run(ff,args,context:context);try validate(output,video:needsVideo,audio:needsAudio,expectedAudioTracks:needsAudio ? (needsVideo ? info.audioTracks.count:1):0,context:context)''',1)
s=s.replace('''    private static func input(_ file:URL)->[String] {["-protocol_whitelist","file,pipe","-i",file.path]}''','''    // Explicitly accept valid one-centisecond delays on all supported FFmpeg versions.
    private static func gifInputOptions(_ file:URL)->[String] {file.pathExtension.lowercased()=="gif" ? ["-min_delay","1","-ignore_loop","1"]:[]}
    private static func input(_ file:URL)->[String] {["-protocol_whitelist","file,pipe"]+gifInputOptions(file)+["-i",file.path]}
    private static let squarePixels="scale=w='max(2,trunc(iw*sar/2+0.5)*2)':h='max(2,trunc(ih/2+0.5)*2)',setsar=1"
    private static func audioMetadata(_ tracks:[LSMAudioTrack])->[String] {
        var args:[String]=[]
        for (index,track) in tracks.enumerated() {
            if !track.language.isEmpty {args += ["-metadata:s:a:\\(index)","language="+track.language]}
            if !track.title.isEmpty {args += ["-metadata:s:a:\\(index)","title="+track.title]}
            args += ["-disposition:a:\\(index)",track.disposition]
        };return args
    }''')
s=s.replace('''["-v","error","-protocol_whitelist","file,pipe","-show_streams","-show_format","-of","json",file.path]''','''["-v","error","-protocol_whitelist","file,pipe"]+gifInputOptions(file)+["-show_streams","-show_format","-of","json",file.path]''')
s=s.replace('''        let audio=streams.first{($0["codec_type"] as? String)=="audio"}''','''        let audioStreams=streams.filter{($0["codec_type"] as? String)=="audio"}
        let audio=audioStreams.first
        let audioTracks=audioStreams.map { stream -> LSMAudioTrack in
            let tags=stream["tags"] as? [String:Any] ?? [:],flags=stream["disposition"] as? [String:Any] ?? [:]
            let known=["default","dub","original","comment","lyrics","karaoke","forced","hearing_impaired","visual_impaired","clean_effects"]
            let enabled=known.filter{(flags[$0] as? Int ?? 0) != 0}
            return LSMAudioTrack(channels:stream["channels"] as? Int ?? 1,language:tags["language"] as? String ?? "",title:tags["title"] as? String ?? "",disposition:enabled.isEmpty ? "0":enabled.joined(separator:"+"))
        }''')
s=s.replace('''        var rotation=Double((video?["tags"]''','''        let ratioParts=(video?["sample_aspect_ratio"] as? String ?? "1:1").split(separator:":").compactMap{Double($0)}
        var sar=ratioParts.count==2 && ratioParts[0]>0 && ratioParts[1]>0 ? ratioParts[0]/ratioParts[1]:1
        if !sar.isFinite || sar<=0 {sar=1}
        var rotation=Double((video?["tags"]''')
s=s.replace('''if Int(abs(rotation).rounded())%180==90 {swap(&width,&height)}''','''if Int(abs(rotation).rounded())%180==90 {swap(&width,&height);sar=1/sar}''')
s=s.replace('''isGIF:(video?["codec_name"] as? String)=="gif")''','''isGIF:(video?["codec_name"] as? String)=="gif",sampleAspectRatio:sar,audioTracks:audioTracks)''')
s=s.replace('''private static func validate(_ output:URL,video:Bool,audio:Bool,context:OperationContext)''','''private static func validate(_ output:URL,video:Bool,audio:Bool,expectedAudioTracks:Int?=nil,context:OperationContext)''')
s=s.replace('''        guard (!video || actual.hasVideo),(!audio || actual.hasAudio) else {throw ConverterError.message("输出缺失预期音轨或视频流。")}
''','''        guard (!video || actual.hasVideo),(!audio || actual.hasAudio) else {throw ConverterError.message("输出缺失预期音轨或视频流。")}
        if let expected=expectedAudioTracks,actual.audioTracks.count != expected {throw ConverterError.message("输出音轨数量不符，已拒绝不完整的结果。")}
''')
s=s.replace('''source=Double(info.width)/Double(info.height);r=source>ratio''','''source=Double(info.width)*info.sampleAspectRatio/Double(info.height);r=source>ratio''')
s=s.replace('''            let prefix=gifTimingPrefix(info);if !prefix.isEmpty {args += ["-vf",prefix.joined(separator:",")]}
            args += ["-frames:v"''','''            var prefix=gifTimingPrefix(info)
            if abs(info.sampleAspectRatio-1)>1e-9 {prefix.append("scale=w='max(1,round(iw*sar))':h=ih,setsar=1")}
            if !prefix.isEmpty {args += ["-vf",prefix.joined(separator:",")]}
            args += ["-frames:v"''')
s=s.replace('''"setpts=PTS-STARTPTS,scale=trunc(iw/2)*2:trunc(ih/2)*2,setsar=1"''','''"setpts=PTS-STARTPTS,scale=trunc(iw/2)*2:trunc(ih/2)*2"''')
s=s.replace('''if info.hasAudio {args += ["-map","0:a:0","-af","asetpts=PTS-STARTPTS"]}''','''if info.hasAudio {args += ["-map","0:a","-af","asetpts=PTS-STARTPTS"]}''')
s=s.replace('''args += codec(format,quality:settings.quality,video:true,audio:info.hasAudio)+[output.path]
            try run(ff,args,context:context);try validate(output,video:true,audio:info.hasAudio,context:context)''','''args += codec(format,quality:settings.quality,video:true,audio:info.hasAudio)+audioMetadata(info.audioTracks)+[output.path]
            try run(ff,args,context:context);try validate(output,video:true,audio:info.hasAudio,expectedAudioTracks:info.audioTracks.count,context:context)''')
# Replace join as a unit: every retained output audio track receives the same temporal filters.
a=s.index('    private static func join(');b=s.index('    private static func visualizer(',a)
s=s[:a]+'''    private static func join(_ files:[URL],settings:ConversionSettings,scratch:URL,ff:String,context:OperationContext,progress:@escaping(Double,String)->Void) throws -> [URL] {
        guard files.count>=2,files.count<=100 else {throw ConverterError.message("拼接需要 2 到 100 个视频。")}
        let infos=try files.map{try probe($0,context:context)}
        guard infos.allSatisfy({$0.hasVideo}) else {throw ConverterError.message("拼接项目缺少视频流。")}
        let first=infos[0],displayWidth=Double(infos[0].width)*infos[0].sampleAspectRatio
        guard displayWidth.isFinite,displayWidth<=16384 else {throw ConverterError.message("视频显示宽度超过支持范围。")}
        let width=even(settings.exactSize ? settings.width:Int(displayWidth.rounded())),height=even(settings.exactSize ? settings.height:first.height)
        let trackCount=max(1,infos.map{$0.audioTracks.count}.max() ?? 0)
        var tracks:[LSMAudioTrack]=[]
        for index in 0..<trackCount {
            let candidates=infos.compactMap{index<$0.audioTracks.count ? $0.audioTracks[index]:nil}
            let language=candidates.map{$0.language.lowercased()}.filter{!$0.isEmpty && $0 != "und"}
            guard Set(language).count<=1 else {throw ConverterError.message("拼接文件的音轨语言顺序不一致，请先整理音轨顺序；没有舍弃任何音轨。")}
            var track=candidates.first ?? LSMAudioTrack(channels:2,language:"",title:"",disposition:index==0 ? "default":"0")
            track.channels=max(1,candidates.map{$0.channels}.max() ?? 2)
            guard track.channels<=8 else {throw ConverterError.message("拼接暂不支持超过八声道的音轨；没有自动下混音轨。")}
            tracks.append(track)
        }
        var lines:[String]=[]
        let parts=scratch.appendingPathComponent("join-parts",isDirectory:true);try fm.createDirectory(at:parts,withIntermediateDirectories:true)
        for (index,file) in files.enumerated() {
            try context.check();let info=infos[index]
            let filename="segment-\\(index).mp4",url=parts.appendingPathComponent(filename)
            var args=input(file)
            if info.audioTracks.count<trackCount {args += ["-f","lavfi","-t",num(info.duration),"-i","anullsrc=r=48000:cl=stereo"]}
            args += ["-map","0:v:0"]
            for trackIndex in 0..<trackCount {args += ["-map",trackIndex<info.audioTracks.count ? "0:a:\\(trackIndex)":"1:a:0"]}
            args += ["-vf",(gifTimingPrefix(info)+[squarePixels,"scale=\\(width):\\(height):force_original_aspect_ratio=decrease,pad=\\(width):\\(height):(ow-iw)/2:(oh-ih)/2:color=black,setsar=1,fps=30,setpts=PTS-STARTPTS"]).joined(separator:","),"-af","aresample=48000,apad,atrim=duration=\\(num(info.duration)),asetpts=PTS-STARTPTS","-t",num(info.duration)]
            args += codec("mp4",quality:settings.quality,video:true,audio:true)
            for (trackIndex,track) in tracks.enumerated() {args += ["-ac:a:\\(trackIndex)",String(track.channels)]}
            args += audioMetadata(tracks)+["-video_track_timescale","90000",url.path]
            try run(ff,args,context:context);lines.append("file '"+filename+"'");progress(0.85*Double(index+1)/Double(files.count),"统一拼接片段")
        }
        let list=parts.appendingPathComponent("segments.txt");try lines.joined(separator:"\\n").appending("\\n").write(to:list,atomically:true,encoding:.utf8)
        let output=out(files[0],suffix:"-joined",format:"mp4",scratch:scratch)
        try run(ff,["-f","concat","-safe","1","-protocol_whitelist","file,pipe","-i",list.path,"-map","0:v:0","-map","0:a","-c","copy","-movflags","+faststart"]+audioMetadata(tracks)+[output.path],context:context)
        try validate(output,video:true,audio:true,expectedAudioTracks:trackCount,context:context);progress(1,"拼接完成");return [output]
    }
'''+s[b:]
# Mask selection uses outward rounding independently of codec crop alignment.
needle='''    private static func redactionFilter(_ info:LSMMediaInfo,regions:[RedactionRegion]) throws -> String {'''
helper='''    private static func redactionRect(_ info:LSMMediaInfo,_ r:NormalizedRect) throws -> (Int,Int,Int,Int) {
        guard [r.x,r.y,r.width,r.height].allSatisfy({$0.isFinite}),r.x>=0,r.y>=0,r.width>0,r.height>0,r.x+r.width<=1.000001,r.y+r.height<=1.000001 else {throw ConverterError.message("视频遮挡框超出范围。")}
        let x=max(0,min(info.width-1,Int(floor(r.x*Double(info.width))))),y=max(0,min(info.height-1,Int(floor(r.y*Double(info.height)))))
        let endX=max(x+1,min(info.width,Int(ceil((r.x+r.width)*Double(info.width))))),endY=max(y+1,min(info.height,Int(ceil((r.y+r.height)*Double(info.height)))))
        return (x,y,endX-x,endY-y)
    }
'''
s=s.replace(needle,helper+needle)
s=s.replace('''var graph="[0:v:0]"+(gifTimingPrefix(info)+["setpts=PTS-STARTPTS"]).joined(separator:",")+"[v0]"''','''var graph="[0:v:0]"+(gifTimingPrefix(info)+["format=yuv444p","setpts=PTS-STARTPTS"]).joined(separator:",")+"[v0]"''')
s=s.replace('''            var s=ConversionSettings();s.cropRect=region.rect
            let r=try cropRect(info,settings:s)''','''            let r=try redactionRect(info,region.rect)''')
s=s.replace('''let radius=max(1,min(24,min(r.2,r.3)/4))''','''let radius=max(1,min(24,min(info.width,info.height)/4))''')
s=s.replace('''[region\\(i)]crop=\\(r.2):\\(r.3):\\(r.0):\\(r.1),boxblur=luma_radius=\\(radius):luma_power=2:chroma_radius=\\(max(1,radius/2))[blur\\(i)];[base\\(i)][blur\\(i)]overlay=x=\\(r.0):y=\\(r.1):enable''','''[region\\(i)]boxblur=luma_radius=\\(radius):luma_power=2:chroma_radius=\\(max(1,radius/2)),crop=\\(r.2):\\(r.3):\\(r.0):\\(r.1):exact=1[blur\\(i)];[base\\(i)][blur\\(i)]overlay=x=\\(r.0):y=\\(r.1):format=auto:enable''')
s=s.replace('''        let audioRate=audio ? Int(max(32_000,min(128_000,Double(max(1,limit))*8/info.duration*0.2))) : 0
        var rate=limit>0 ? Int(max(16_000,min(1_000_000_000,Double(limit)*8/info.duration*0.92-Double(audioRate)))):0''','''        let audioTrackCount=audio ? (video ? info.audioTracks.count:1):0
        let audioRate=audio ? Int(max(32_000,min(128_000,Double(max(1,limit))*8/info.duration*0.2/Double(max(1,audioTrackCount))))) : 0
        var rate=limit>0 ? Int(max(16_000,min(1_000_000_000,Double(limit)*8/info.duration*0.92-Double(audioRate*audioTrackCount)))):0''')
s=s.replace('''["scale=trunc(iw/2)*2:trunc(ih/2)*2,setsar=1"]''','''["scale=trunc(iw/2)*2:trunc(ih/2)*2"]''')
s=s.replace('''if audio {args += ["-map","0:a:0"]}''','''if audio {args += ["-map",video ? "0:a":"0:a:0"]}''')
s=s.replace('''            args += ["-map_metadata","-1",output.path]
            try run(ff,args,context:context);try validate(output,video:video,audio:audio,context:context)''','''            if audio,video {args += audioMetadata(info.audioTracks)}
            args += ["-map_metadata","-1",output.path]
            try run(ff,args,context:context);try validate(output,video:video,audio:audio,expectedAudioTracks:audioTrackCount,context:context)''')
p.write_text(s)
