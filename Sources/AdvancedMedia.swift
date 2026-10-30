import Foundation
import ImageIO

private struct LSMAudioTrack {
    var channels:Int
    var language:String
    var title:String
    var disposition:String
}
private struct LSMMediaInfo {
    var duration:Double;var width:Int;var height:Int;var hasVideo:Bool;var hasAudio:Bool;var channels:Int;var isStillGIF:Bool;var isGIF:Bool;var sampleAspectRatio:Double;var audioTracks:[LSMAudioTrack]
}
/// Offline FFmpeg jobs, constrained to the caller's scratch directory.
enum AdvancedMedia {
    private static let fm=FileManager.default
    static func convert(_ files:[URL], option:String, settings:ConversionSettings, scratch:URL,
                        context:OperationContext, progress:@escaping(Double,String)->Void) throws -> [URL] {
        guard let file=files.first else {throw ConverterError.message("没有输入媒体。")}
        guard let ff=OperationContext.executable("ffmpeg") else {throw ConverterError.message("FFmpeg 不可用。")}
        try context.check()
        let info=try probe(file,context:context)
        let isVideo=info.hasVideo && !["mp3","m4a","wav","flac","ogg","opus","aiff","aif","wma","aac"].contains(file.pathExtension.lowercased())
        progress(0.02,"读取媒体信息")
        if option=="joinVideos" {return try join(files,settings:settings,scratch:scratch,ff:ff,context:context,progress:progress)}
        if option=="videoSnapshots" {return try snapshots(file,info:info,settings:settings,scratch:scratch,ff:ff,context:context,progress:progress)}
        if option=="splitVideo" {return try split(file,info:info,settings:settings,scratch:scratch,ff:ff,context:context,progress:progress)}
        if option=="audioToVideo" {return [try visualizer(file,info:info,settings:settings,scratch:scratch,ff:ff,context:context)]}
        let original=normalize(file.pathExtension)
        var format=option.hasPrefix("format_") ? String(option.dropFirst(7)) : (settings.outputFormat.isEmpty ? original : normalize(settings.outputFormat))
        if option=="compress",settings.outputFormat.isEmpty {format=isVideo ? "mp4":"mp3"}
        if !option.hasPrefix("format_"),original=="gif",option != "removeMetadata" {format="mp4"}
        if !videoFormats.contains(format) && !audioFormats.contains(format) {format=isVideo ? "mp4":"m4a"}
        let output=out(file,suffix:option.hasPrefix("format_") ? "":"-"+option,format:format,scratch:scratch)
        if option=="removeMetadata" {
            var args=input(file)+["-map","0","-c","copy"]
            if settings.removeMetadata {args += ["-map_metadata","-1","-map_metadata:s","-1","-map_chapters","-1","-metadata","encoder=","-metadata:s","encoder="]}
            for key in settings.metadata.keys.sorted() {
                guard !key.contains("\0"),!(settings.metadata[key] ?? "").contains("\0") else {throw ConverterError.message("元数据包含无效字符。")}
                args += ["-metadata",key+"="+(settings.metadata[key] ?? "")]
            }
            if ["mp4","mov","m4a"].contains(format) {args += ["-movflags","+faststart+use_metadata_tags"]}
            try run(ff,args+[output.path],context:context);try validate(output,video:info.hasVideo,audio:info.hasAudio,context:context);progress(1,"元数据处理完成");return [output]
        }
        if option=="compress" {
            try compress(file,info:info,format:format,to:output,settings:settings,ff:ff,context:context,progress:progress);return [output]
        }
        var args=input(file),videoFilter:[String]=gifTimingPrefix(info),audioFilter:[String]=[]
        var needsVideo=isVideo && videoFormats.contains(format),needsAudio=info.hasAudio && format != "gif"
        var complex:String?=nil
        var videoMap="0:v:0",audioMap="0:a:0"
        switch option {
        case "normalizeAudio":
            guard info.hasAudio,settings.normalizeTarget.isFinite,(-40 ... -5).contains(settings.normalizeTarget) else {throw ConverterError.message("响度目标必须在 -40 到 -5 LUFS 之间。")}
            // Two-pass EBU R128 normalization measures the real source before applying gain.
            let measurement=try context.run(ff,["-nostdin","-hide_banner","-v","info"]+input(file)+["-vn","-af","loudnorm=I=\(num(settings.normalizeTarget)):TP=-1.5:LRA=11:print_format=json","-f","null","-"])
            guard let data=jsonObject(in:measurement),let measured=try? JSONSerialization.jsonObject(with:data) as? [String:Any] else {throw ConverterError.message("无法测量音频响度。")}
            func measuredValue(_ k:String)->String? {let value=(measured[k] as? String) ?? "";guard let n=Double(value),n.isFinite else {return nil};return num(n)}
            if let i=measuredValue("input_i"),let tp=measuredValue("input_tp"),let lra=measuredValue("input_lra"),let threshold=measuredValue("input_thresh"),let offset=measuredValue("target_offset") {
                audioFilter.append("loudnorm=I=\(num(settings.normalizeTarget)):TP=-1.5:LRA=11:measured_I=\(i):measured_TP=\(tp):measured_LRA=\(lra):measured_thresh=\(threshold):offset=\(offset):linear=true")
            } else {throw ConverterError.message("音频为静音或响度不可测量。")}
        case "muteVideo":guard info.hasVideo else {throw ConverterError.message("输入没有视频流。")};needsAudio=false
        case "trimVideo","trimAudio":
            let range=try trimRange(info,settings:settings)
            if needsVideo {videoFilter.append("trim=start=\(num(range.start)):end=\(num(range.end)),setpts=PTS-STARTPTS")}
            if needsAudio {audioFilter.append("atrim=start=\(num(range.start)):end=\(num(range.end)),asetpts=PTS-STARTPTS")}
            if option=="trimAudio",settings.trimSilence {
                // Reverse twice removes only edge silence; internal pauses remain intact.
                audioFilter += ["silenceremove=start_periods=1:start_duration=0.02:start_threshold=-45dB", "areverse", "silenceremove=start_periods=1:start_duration=0.02:start_threshold=-45dB", "areverse", "asetpts=PTS-STARTPTS"]
            }
        case "cropVideo":
            guard info.hasVideo else {throw ConverterError.message("输入没有视频流。")}
            let rect=try cropRect(info,settings:settings)
            videoFilter.append("crop=\(rect.2):\(rect.3):\(rect.0):\(rect.1)")
            if settings.exactSize {videoFilter.append("scale=\(even(settings.width)):\(even(settings.height)),setsar=1")}
        case "changeVideoSpeed","speed":
            guard settings.speed.isFinite,(0.125...8).contains(settings.speed) else {throw ConverterError.message("速度必须在 0.125 到 8 倍之间。")}
            if needsVideo {videoFilter.append("setpts=(PTS-STARTPTS)/\(num(settings.speed))")}
            if needsAudio {audioFilter.append(atempo(settings.speed))}
        case "audioChannels":
            guard info.hasAudio,[1,2].contains(settings.channels) else {throw ConverterError.message("声道数只能为 1 或 2。")}
            args += ["-ac",String(settings.channels)]
        case "redactAudio":
            guard info.hasAudio,settings.bleepFrequency.isFinite,(settings.bleepFrequency==0 || (100...8000).contains(settings.bleepFrequency)) else {throw ConverterError.message("提示音频率为 0（静音），或 100 到 8000 Hz。")}
            let ranges=try mergedRanges(settings.bleepRanges,duration:info.duration)
            guard !ranges.isEmpty else {throw ConverterError.message("请选择需要提示音替换的时间段。")}
            let condition=ranges.map{"gte(t,\(num($0.start)))*lt(t,\(num($0.end)))"}.joined(separator:"+")
            let channels=max(1,min(8,info.channels))
            let expressions=(0..<channels).map{"if(gt(\(condition),0),0.2*sin(2*PI*\(num(settings.bleepFrequency))*t),val(\($0)))"}.joined(separator:"|")
            audioFilter.append("aeval=exprs='\(expressions)'")
        case "redactVideo":
            guard needsVideo,!settings.redactions.isEmpty else {throw ConverterError.message("请选择视频遮挡区域。")}
            complex=try redactionFilter(info,regions:settings.redactions);videoMap="vout";videoFilter=[]
        default:guard option.hasPrefix("format_") else {throw ConverterError.message("不支持的媒体操作："+option)}
        }
        if audioFormats.contains(format) {needsVideo=false;guard info.hasAudio else {throw ConverterError.message("输入没有可导出的音轨。")};needsAudio=true}
        if needsVideo {
            videoFilter.append("scale=trunc(iw/2)*2:trunc(ih/2)*2")
            if complex != nil {complex! += ";[vout]"+videoFilter.joined(separator:",")+"[vfinal]";videoMap="vfinal"}
        }
        audioMap=needsVideo ? "0:a":"0:a:0"
        if let graph=complex {args += ["-filter_complex",graph]}
        if needsVideo {args += ["-map",videoMap.hasPrefix("0:") ? videoMap : "["+videoMap+"]"];if complex==nil,!videoFilter.isEmpty {args += ["-vf",videoFilter.joined(separator:",")]}}
        if needsAudio {args += ["-map",audioMap];if !audioFilter.isEmpty {args += ["-af",audioFilter.joined(separator:",")]}}
        else {args += ["-an"]}
        if !needsVideo {args += ["-vn"]}
        let codingFormat=(option=="audioChannels" && format=="ogg" && settings.channels==1) ? "opus":format
        args += codec(codingFormat,quality:settings.quality,video:needsVideo,audio:needsAudio)
        if option=="audioChannels" {
            if format=="ogg",settings.channels==1 {args += ["-c:a","libopus","-ar","48000"]}
            args += ["-ac",String(settings.channels)]
        }
        if format=="gif" {
            // Palette generation keeps conversion output animated and avoids a fixed coarse palette.
            args.removeAll(where:{$0=="-an"})
            let chain=(videoFilter+[squarePixels]).joined(separator:",")+",fps=15,split[p0][p1];[p0]palettegen=reserve_transparent=1[palette];[p1][palette]paletteuse=dither=sierra2_4a"
            args=input(file)+["-filter_complex",chain,"-an","-loop","0"]
        }
        if needsAudio,needsVideo {args += audioMetadata(info.audioTracks)}
        args += ["-map_metadata","-1",output.path]
        try run(ff,args,context:context);try validate(output,video:needsVideo,audio:needsAudio,expectedAudioTracks:needsAudio ? (needsVideo ? info.audioTracks.count:1):0,context:context)
        progress(1,"媒体处理完成");return [output]
    }
    private static let videoFormats=Set(["mp4","mov","mkv","webm","avi","wmv","gif"])
    private static let audioFormats=Set(["mp3","m4a","wav","flac","ogg","opus","aiff","wma","aac"])
    private static func normalize(_ value:String)->String {let s=value.lowercased();return ["aif":"aiff","m4v":"mp4"][s] ?? s}
    private static func out(_ file:URL,suffix:String,format:String,scratch:URL)->URL {scratch.appendingPathComponent(file.deletingPathExtension().lastPathComponent+suffix+"."+format)}
    private static func num(_ value:Double)->String {String(format:"%.8f",locale:Locale(identifier:"en_US_POSIX"),value)}
    private static func even(_ n:Int)->Int {max(2,n/2*2)}
    // Explicitly accept valid one-centisecond delays on all supported FFmpeg versions.
    private static func gifInputOptions(_ file:URL)->[String] {file.pathExtension.lowercased()=="gif" ? ["-min_delay","1","-ignore_loop","1"]:[]}
    private static func input(_ file:URL)->[String] {["-protocol_whitelist","file,pipe"]+gifInputOptions(file)+["-i",file.path]}
    private static let squarePixels="scale=w='max(2,trunc(iw*sar/2+0.5)*2)':h='max(2,trunc(ih/2+0.5)*2)',setsar=1"
    private static func audioMetadata(_ tracks:[LSMAudioTrack])->[String] {
        var args:[String]=[]
        for (index,track) in tracks.enumerated() {
            if !track.language.isEmpty {args += ["-metadata:s:a:\(index)","language="+track.language]}
            if !track.title.isEmpty {args += ["-metadata:s:a:\(index)","title="+track.title]}
            args += ["-disposition:a:\(index)",track.disposition]
        };return args
    }
    private static func gifTimingPrefix(_ info:LSMMediaInfo)->[String] {
        // GIF delays use centiseconds. FFmpeg's guessed average frame rate can
        // flatten variable delays and truncate the final hold. Resample the real
        // timeline on its 10 ms grid, pad the last frame, then trim to the measured
        // duration. An untimed single still receives a one-second, 30 fps hold.
        guard info.isGIF else {return []}
        return ["tpad=stop_mode=clone:stop_duration=\(num(info.duration))","fps=\(info.isStillGIF ? 30:100)","trim=duration=\(num(info.duration))","setpts=PTS-STARTPTS"]
    }
    private static func run(_ ff:String,_ args:[String],context:OperationContext) throws {try context.run(ff,["-nostdin","-hide_banner","-v","error","-y"]+args)}
    private static func probe(_ file:URL,context:OperationContext) throws -> LSMMediaInfo {
        guard let ffprobe=OperationContext.executable("ffprobe") else {throw ConverterError.message("ffprobe 不可用，无法安全读取媒体参数。")}
        let text=try context.run(ffprobe,["-v","error","-protocol_whitelist","file,pipe"]+gifInputOptions(file)+["-show_streams","-show_format","-of","json",file.path])
        guard let data=text.data(using:.utf8),let obj=try JSONSerialization.jsonObject(with:data) as? [String:Any] else {throw ConverterError.message("无法读取媒体信息。")}
        let streams=obj["streams"] as? [[String:Any]] ?? []
        let video=streams.first{($0["codec_type"] as? String)=="video" && (($0["disposition"] as? [String:Any])?["attached_pic"] as? Int ?? 0)==0}
        let audioStreams=streams.filter{($0["codec_type"] as? String)=="audio"}
        let audio=audioStreams.first
        let audioTracks=audioStreams.map { stream -> LSMAudioTrack in
            let tags=stream["tags"] as? [String:Any] ?? [:],flags=stream["disposition"] as? [String:Any] ?? [:]
            let known=["default","dub","original","comment","lyrics","karaoke","forced","hearing_impaired","visual_impaired","clean_effects"]
            let enabled=known.filter{(flags[$0] as? Int ?? 0) != 0}
            return LSMAudioTrack(channels:stream["channels"] as? Int ?? 1,language:tags["language"] as? String ?? "",title:tags["title"] as? String ?? "",disposition:enabled.isEmpty ? "0":enabled.joined(separator:"+"))
        }
        let format=obj["format"] as? [String:Any] ?? [:]
        var duration=Double(format["duration"] as? String ?? "") ?? 0
        if duration<=0 {duration=streams.compactMap{Double($0["duration"] as? String ?? "")}.max() ?? 0}
        var isStillGIF=false
        if (video?["codec_name"] as? String)=="gif" {
            if let source=CGImageSourceCreateWithURL(file as CFURL,[kCGImageSourceShouldCache:false] as CFDictionary) {
                let count=CGImageSourceGetCount(source);isStillGIF=count==1
                if !duration.isFinite || duration<=0 {
                    var total:Double=0
                    for index in 0..<count {
                        try context.check()
                        let props=CGImageSourceCopyPropertiesAtIndex(source,index,nil) as? [CFString:Any] ?? [:]
                        let gif=props[kCGImagePropertyGIFDictionary] as? [CFString:Any] ?? [:]
                        let delay=(gif[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue ?? (gif[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue ?? 0
                        total += delay.isFinite && delay>0 ? delay : (count==1 ? 1:0.1)
                    }
                    duration=total
                }
            } else if (video?["nb_frames"] as? String)=="1" {
                isStillGIF=true;if !duration.isFinite || duration<=0 {duration=1}
            }
        }
        guard duration.isFinite,duration>0,video != nil || audio != nil else {throw ConverterError.message("媒体没有有效时长或可处理的音视频流。")}
        var width=video?["width"] as? Int ?? 0,height=video?["height"] as? Int ?? 0
        let ratioParts=(video?["sample_aspect_ratio"] as? String ?? "1:1").split(separator:":").compactMap{Double($0)}
        var sar=ratioParts.count==2 && ratioParts[0]>0 && ratioParts[1]>0 ? ratioParts[0]/ratioParts[1]:1
        if !sar.isFinite || sar<=0 {sar=1}
        var rotation=Double((video?["tags"] as? [String:Any])?["rotate"] as? String ?? "") ?? 0
        if let side=video?["side_data_list"] as? [[String:Any]],let r=side.compactMap({$0["rotation"] as? Double}).first {rotation=r}
        if Int(abs(rotation).rounded())%180==90 {swap(&width,&height);sar=1/sar}
        if video != nil, width<2 || height<2 || width>16384 || height>16384 {throw ConverterError.message("视频尺寸无效或超过 16384。")}
        return LSMMediaInfo(duration:duration,width:width,height:height,hasVideo:video != nil,hasAudio:audio != nil,channels:audio?["channels"] as? Int ?? 0,isStillGIF:isStillGIF,isGIF:(video?["codec_name"] as? String)=="gif",sampleAspectRatio:sar,audioTracks:audioTracks)
    }
    private static func validate(_ output:URL,video:Bool,audio:Bool,expectedAudioTracks:Int?=nil,context:OperationContext) throws {
        guard fm.fileExists(atPath:output.path),((try output.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0)>0 else {throw ConverterError.message("媒体输出为空。")}
        let actual=try probe(output,context:context)
        guard (!video || actual.hasVideo),(!audio || actual.hasAudio) else {throw ConverterError.message("输出缺失预期音轨或视频流。")}
        if let expected=expectedAudioTracks,actual.audioTracks.count != expected {throw ConverterError.message("输出音轨数量不符，已拒绝不完整的结果。")}
    }
    private static func codec(_ format:String,quality:Double,video:Bool,audio:Bool,bitrate:Int?=nil)->[String] {
        let q=max(0,min(1,quality)),audioRate=max(32_000,Int(64_000+q*192_000))
        var args:[String]=[]
        if video {
            switch format {
            case "webm":args += ["-c:v","libvpx-vp9","-deadline","good","-cpu-used","4","-crf",String(Int(18+(1-q)*30)),"-b:v",bitrate.map(String.init) ?? "0","-pix_fmt","yuv420p"]
            case "wmv":args += ["-c:v","wmv2","-b:v",String(bitrate ?? Int(500_000+q*4_000_000)),"-pix_fmt","yuv420p"]
            case "avi":args += ["-c:v","mpeg4","-q:v",String(max(2,Int(2+(1-q)*24))),"-pix_fmt","yuv420p"];if let rate=bitrate {args += ["-b:v",String(rate)]}
            case "gif":break
            default:args += ["-c:v","libx264","-preset","medium","-pix_fmt","yuv420p"];if let rate=bitrate {args += ["-b:v",String(rate),"-maxrate",String(rate),"-bufsize",String(rate*2)]} else {args += ["-crf",String(Int(16+(1-q)*28))]}
            }
        }
        if audio {
            switch format {
            case "mp3","avi":args += ["-c:a","libmp3lame","-b:a",String(audioRate)]
            case "wav":args += ["-c:a","pcm_s16le"]
            case "aiff":args += ["-c:a","pcm_s16be"]
            case "flac":args += ["-c:a","flac","-compression_level","8"]
            case "ogg":args += ["-c:a","vorbis","-strict","experimental","-q:a",String(2+Int(q*6)),"-ac","2"]
            case "opus","webm":args += ["-c:a","libopus","-b:a",String(min(256_000,audioRate)),"-ar","48000"]
            case "wma","wmv":args += ["-c:a","wmav2","-b:a",String(min(192_000,audioRate)),"-ar","44100","-ac","2"]
            default:args += ["-c:a","aac","-b:a",String(audioRate)]
            }
        }
        if ["mp4","mov","m4a"].contains(format) {args += ["-movflags","+faststart"]}
        return args
    }
    private static func trimRange(_ info:LSMMediaInfo,settings:ConversionSettings) throws -> TimeRange {
        guard settings.startSeconds.isFinite,settings.endSeconds.isFinite,settings.startSeconds>=0,settings.startSeconds<info.duration,settings.endSeconds>settings.startSeconds else {throw ConverterError.message("裁剪起止时间无效。")}
        return TimeRange(start:settings.startSeconds,end:min(info.duration,settings.endSeconds))
    }
    private static func atempo(_ speed:Double)->String {
        var remaining=speed,parts:[String]=[]
        while remaining>2 {parts.append("atempo=2");remaining/=2}
        while remaining<0.5 {parts.append("atempo=0.5");remaining/=0.5}
        parts.append("atempo="+num(remaining));return parts.joined(separator:",")
    }
    private static func cropRect(_ info:LSMMediaInfo,settings:ConversionSettings) throws -> (Int,Int,Int,Int) {
        var r=settings.cropRect
        if r==nil {let ratio=Double(settings.width)/Double(settings.height),source=Double(info.width)*info.sampleAspectRatio/Double(info.height);r=source>ratio ? NormalizedRect(x:(1-ratio/source)/2,y:0,width:ratio/source,height:1):NormalizedRect(x:0,y:(1-source/ratio)/2,width:1,height:source/ratio)}
        let rect=r!
        guard [rect.x,rect.y,rect.width,rect.height].allSatisfy({$0.isFinite}),rect.x>=0,rect.y>=0,rect.width>0,rect.height>0,rect.x+rect.width<=1.000001,rect.y+rect.height<=1.000001 else {throw ConverterError.message("视频裁剪框超出范围。")}
        // Decimal normalized coordinates such as0.7*180 can be125.999999999;
        // stabilize the pixel boundary before codec-required even alignment.
        func pixel(_ value: Double) -> Int { Int(floor(value+1e-7)) }
        let x=max(0,pixel(rect.x*Double(info.width))/2*2),y=max(0,pixel(rect.y*Double(info.height))/2*2)
        let w=min(even(pixel(rect.width*Double(info.width))),even(info.width-x)),h=min(even(pixel(rect.height*Double(info.height))),even(info.height-y))
        guard x+w<=info.width,y+h<=info.height,w>=2,h>=2 else {throw ConverterError.message("视频裁剪范围过小。")};return (x,y,w,h)
    }
    private static func snapshots(_ file:URL,info:LSMMediaInfo,settings:ConversionSettings,scratch:URL,ff:String,context:OperationContext,progress:@escaping(Double,String)->Void) throws -> [URL] {
        guard info.hasVideo else {throw ConverterError.message("输入没有视频帧。")}
        let times=settings.snapshotTimes.isEmpty ? [settings.startSeconds]:settings.snapshotTimes
        guard times.count<=500,times.allSatisfy({$0.isFinite && $0>=0 && $0<info.duration}) else {throw ConverterError.message("截图时间超出视频范围，或截图超过 500 张。")}
        var urls:[URL]=[]
        for (index,time) in times.enumerated() {
            try context.check();let url=out(file,suffix:String(format:"-snapshot-%04d",index+1),format:"png",scratch:scratch)
            var args=input(file)+["-ss",num(time),"-map","0:v:0"]
            var prefix=gifTimingPrefix(info)
            if abs(info.sampleAspectRatio-1)>1e-9 {prefix.append("scale=w='max(1,round(iw*sar))':h=ih,setsar=1")}
            if !prefix.isEmpty {args += ["-vf",prefix.joined(separator:",")]}
            args += ["-frames:v","1","-update","1",url.path]
            try run(ff,args,context:context)
            guard ((try url.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0)>0 else {throw ConverterError.message("指定时间没有可解码帧。")}
            urls.append(url);progress(Double(index+1)/Double(times.count),"提取视频截图")
        };return urls
    }
    private static func split(_ file:URL,info:LSMMediaInfo,settings:ConversionSettings,scratch:URL,ff:String,context:OperationContext,progress:@escaping(Double,String)->Void) throws -> [URL] {
        guard info.hasVideo,!settings.splitPoints.isEmpty,settings.splitPoints.count<=500,settings.splitPoints.allSatisfy({$0.isFinite && $0>0 && $0<info.duration}) else {throw ConverterError.message("分割点必须在视频时长内，至少一个、最多 500 个。")}
        let points=[0]+Array(Set(settings.splitPoints)).sorted()+[info.duration]
        let format=videoFormats.contains(normalize(file.pathExtension)) && normalize(file.pathExtension) != "gif" ? normalize(file.pathExtension):"mp4"
        var urls:[URL]=[]
        for index in 0..<(points.count-1) {
            try context.check();let output=out(file,suffix:String(format:"-part-%04d",index+1),format:format,scratch:scratch)
            var args=input(file)+["-ss",num(points[index]),"-t",num(points[index+1]-points[index]),"-map","0:v:0","-vf",(gifTimingPrefix(info)+["setpts=PTS-STARTPTS,scale=trunc(iw/2)*2:trunc(ih/2)*2"]).joined(separator:",")]
            if info.hasAudio {args += ["-map","0:a","-af","asetpts=PTS-STARTPTS"]} else {args += ["-an"]}
            args += codec(format,quality:settings.quality,video:true,audio:info.hasAudio)+audioMetadata(info.audioTracks)+[output.path]
            try run(ff,args,context:context);try validate(output,video:true,audio:info.hasAudio,expectedAudioTracks:info.audioTracks.count,context:context);urls.append(output)
            progress(Double(index+1)/Double(points.count-1),"导出所有分段")
        };return urls
    }
    private static func join(_ files:[URL],settings:ConversionSettings,scratch:URL,ff:String,context:OperationContext,progress:@escaping(Double,String)->Void) throws -> [URL] {
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
            let filename="segment-\(index).mp4",url=parts.appendingPathComponent(filename)
            var args=input(file)
            if info.audioTracks.count<trackCount {args += ["-f","lavfi","-t",num(info.duration),"-i","anullsrc=r=48000:cl=stereo"]}
            args += ["-map","0:v:0"]
            for trackIndex in 0..<trackCount {args += ["-map",trackIndex<info.audioTracks.count ? "0:a:\(trackIndex)":"1:a:0"]}
            args += ["-vf",(gifTimingPrefix(info)+[squarePixels,"scale=\(width):\(height):force_original_aspect_ratio=decrease,pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2:color=black,setsar=1,fps=30,setpts=PTS-STARTPTS"]).joined(separator:","),"-af","aresample=48000,apad,atrim=duration=\(num(info.duration)),asetpts=PTS-STARTPTS","-t",num(info.duration)]
            args += codec("mp4",quality:settings.quality,video:true,audio:true)
            for (trackIndex,track) in tracks.enumerated() {args += ["-ac:a:\(trackIndex)",String(track.channels)]}
            args += audioMetadata(tracks)+["-video_track_timescale","90000",url.path]
            try run(ff,args,context:context);lines.append("file '"+filename+"'");progress(0.85*Double(index+1)/Double(files.count),"统一拼接片段")
        }
        let list=parts.appendingPathComponent("segments.txt");try lines.joined(separator:"\n").appending("\n").write(to:list,atomically:true,encoding:.utf8)
        let output=out(files[0],suffix:"-joined",format:"mp4",scratch:scratch)
        try run(ff,["-f","concat","-safe","1","-protocol_whitelist","file,pipe","-i",list.path,"-map","0:v:0","-map","0:a","-c","copy","-movflags","+faststart"]+audioMetadata(tracks)+[output.path],context:context)
        try validate(output,video:true,audio:true,expectedAudioTracks:trackCount,context:context);progress(1,"拼接完成");return [output]
    }
    private static func visualizer(_ file:URL,info:LSMMediaInfo,settings:ConversionSettings,scratch:URL,ff:String,context:OperationContext) throws -> URL {
        guard info.hasAudio else {throw ConverterError.message("输入没有音轨。")}
        let size:(Int,Int)
        switch settings.visualizerLayout {case "portrait":size=(1080,1920);case "square":size=(1080,1080);case "landscape":size=(1920,1080);default:throw ConverterError.message("音频可视化画幅无效。")}
        let output=out(file,suffix:"-visualizer",format:"mp4",scratch:scratch)
        let waveH=max(64,size.1/3)
        var args=input(file)
        let graph:String
        if let background=settings.backgroundImage {
            guard fm.isReadableFile(atPath:background.path) else {throw ConverterError.message("无法读取背景图片。")}
            args += ["-loop","1"]+input(background)
            graph="[0:a:0]showwaves=s=\(size.0)x\(waveH):mode=cline:rate=30:colors=0xFF8A32:scale=sqrt,format=rgba,colorkey=black:0.01:0.01[wave];[1:v]scale=\(size.0):\(size.1):force_original_aspect_ratio=increase,crop=\(size.0):\(size.1),setsar=1[bg];[bg][wave]overlay=0:(H-h)/2:shortest=1,format=yuv420p[v]"
        } else {
            graph="[0:a:0]showwaves=s=\(size.0)x\(waveH):mode=cline:rate=30:colors=0xFF8A32:scale=sqrt,pad=\(size.0):\(size.1):0:(oh-ih)/2:color=black,format=yuv420p[v]"
        }
        args += ["-filter_complex",graph,"-map","[v]","-map","0:a:0","-t",num(info.duration),"-shortest"]
        args += codec("mp4",quality:settings.quality,video:true,audio:true)+[output.path]
        try run(ff,args,context:context);try validate(output,video:true,audio:true,context:context);return output
    }
    private static func redactionRect(_ info:LSMMediaInfo,_ r:NormalizedRect) throws -> (Int,Int,Int,Int) {
        guard [r.x,r.y,r.width,r.height].allSatisfy({$0.isFinite}),r.x>=0,r.y>=0,r.width>0,r.height>0,r.x+r.width<=1.000001,r.y+r.height<=1.000001 else {throw ConverterError.message("视频遮挡框超出范围。")}
        let x=max(0,min(info.width-1,Int(floor(r.x*Double(info.width))))),y=max(0,min(info.height-1,Int(floor(r.y*Double(info.height)))))
        let endX=max(x+1,min(info.width,Int(ceil((r.x+r.width)*Double(info.width))))),endY=max(y+1,min(info.height,Int(ceil((r.y+r.height)*Double(info.height)))))
        return (x,y,endX-x,endY-y)
    }
    private static func redactionFilter(_ info:LSMMediaInfo,regions:[RedactionRegion]) throws -> String {
        guard regions.count<=100 else {throw ConverterError.message("视频遮挡区域超过 100 个。")}
        var graph="[0:v:0]"+(gifTimingPrefix(info)+["format=yuv444p","setpts=PTS-STARTPTS"]).joined(separator:",")+"[v0]"
        for (i,region) in regions.enumerated() {
            let r=try redactionRect(info,region.rect)
            guard region.start.isFinite,region.start>=0,region.start<info.duration,region.end>region.start else {throw ConverterError.message("视频遮挡时间无效。")}
            let end=min(info.duration,region.end),enable="gte(t,\(num(region.start)))*lt(t,\(num(end)))"
            if region.style=="solid" {
                let hex=region.colorHex.replacingOccurrences(of:"#",with:"")
                guard [6,8].contains(hex.count),UInt64(hex,radix:16) != nil else {throw ConverterError.message("遮挡颜色需要六位或八位十六进制。")}
                graph += ";[v\(i)]drawbox=x=\(r.0):y=\(r.1):w=\(r.2):h=\(r.3):color=0x\(hex):t=fill:enable='\(enable)'[v\(i+1)]"
            } else if region.style=="blur" {
                let radius=max(1,min(24,min(info.width,info.height)/4))
                graph += ";[v\(i)]split=2[base\(i)][region\(i)];[region\(i)]boxblur=luma_radius=\(radius):luma_power=2:chroma_radius=\(max(1,radius/2)),crop=\(r.2):\(r.3):\(r.0):\(r.1):exact=1[blur\(i)];[base\(i)][blur\(i)]overlay=x=\(r.0):y=\(r.1):format=auto:enable='\(enable)'[v\(i+1)]"
            } else {throw ConverterError.message("未知视频遮挡样式。")}
        }
        graph += ";[v\(regions.count)]null[vout]";return graph
    }
    private static func mergedRanges(_ ranges:[TimeRange],duration:Double) throws -> [TimeRange] {
        guard ranges.count<=1000 else {throw ConverterError.message("音频遮挡区段超过 1000 个。")}
        var sorted:[TimeRange]=[]
        for r in ranges {guard r.start.isFinite,r.end.isFinite,r.start>=0,r.end>r.start,r.start<duration else {throw ConverterError.message("音频提示音时间无效。")};sorted.append(TimeRange(start:r.start,end:min(duration,r.end)))}
        sorted.sort{$0.start<$1.start};var merged:[TimeRange]=[]
        for range in sorted {if let last=merged.last,last.end>=range.start {merged[merged.count-1].end=max(last.end,range.end)} else {merged.append(range)}};return merged
    }
    private static func jsonObject(in text:String)->Data? {
        guard let start=text.range(of:"{",options:.backwards),let end=text.range(of:"}",options:.backwards),start.lowerBound<end.upperBound else {return nil}
        return String(text[start.lowerBound..<end.upperBound]).data(using:.utf8)
    }
    private static func compress(_ file:URL,info:LSMMediaInfo,format:String,to output:URL,settings:ConversionSettings,ff:String,context:OperationContext,progress:@escaping(Double,String)->Void) throws {
        let video=info.hasVideo && videoFormats.contains(format),audio=info.hasAudio && format != "gif"
        guard video || audio else {throw ConverterError.message("没有可压缩的媒体流。")}
        var limit:Int64=0
        if settings.compressionMode=="target" {guard settings.targetBytes>0 else {throw ConverterError.message("请输入有效的目标字节数。")};limit=settings.targetBytes}
        if settings.compressionMode=="percent" {
            guard settings.reductionPercent.isFinite,(0..<100).contains(settings.reductionPercent) else {throw ConverterError.message("压缩百分比无效。")}
            limit=Int64(Double((try file.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0)*(1-settings.reductionPercent/100))
        }
        let audioTrackCount=audio ? (video ? info.audioTracks.count:1):0
        let audioRate=audio ? Int(max(32_000,min(128_000,Double(max(1,limit))*8/info.duration*0.2/Double(max(1,audioTrackCount))))) : 0
        var rate=limit>0 ? Int(max(16_000,min(1_000_000_000,Double(limit)*8/info.duration*0.92-Double(audioRate*audioTrackCount)))):0
        for attempt in 0..<(limit>0 ? 5:1) {
            try context.check();var args=input(file)
            if video {args += ["-map","0:v:0","-vf",(gifTimingPrefix(info)+["scale=trunc(iw/2)*2:trunc(ih/2)*2"]).joined(separator:",")]} else {args += ["-vn"]}
            if audio {args += ["-map",video ? "0:a":"0:a:0"]} else {args += ["-an"]}
            args += codec(format,quality:max(0.02,settings.quality-Double(attempt)*0.18),video:video,audio:audio,bitrate:rate>0 ? rate:nil)
            if limit>0,audio,!(["wav","aiff","flac"].contains(format)) {args += ["-b:a",String(audioRate)]}
            if audio,video {args += audioMetadata(info.audioTracks)}
            args += ["-map_metadata","-1",output.path]
            try run(ff,args,context:context);try validate(output,video:video,audio:audio,expectedAudioTracks:audioTrackCount,context:context)
            let bytes=(try fm.attributesOfItem(atPath:output.path)[.size] as? NSNumber)?.int64Value ?? 0
            progress(Double(attempt+1)/5,"压缩媒体")
            if limit==0 || bytes<=limit {progress(1,"压缩完成");return}
            rate=max(8_000,Int(Double(rate)*Double(limit)/Double(max(1,bytes))*0.85))
        }
        throw ConverterError.message("无法在可用编码器限制内达到目标大小，请提高上限或选择有损格式。未输出超过上限的结果。")
    }
}
