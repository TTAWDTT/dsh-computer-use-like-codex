import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreVideo
let output=CommandLine.arguments[1]
let lock=NSLock()
func record(_ values:[String:Any]) {
    var row=values;row["wall_ms"]=Date().timeIntervalSince1970*1000
    guard let data=try? JSONSerialization.data(withJSONObject:row)else{return}
    lock.lock();defer{lock.unlock()}
    if let h=FileHandle(forWritingAtPath:output){h.seekToEndOfFile();h.write(data);h.write(Data([10]));try? h.close()}
}
class Observer:NSObject,SCStreamOutput,SCStreamDelegate{
    var stream:SCStream?
    func start()async {
        do{
            let content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:false)
            let display=content.displays.first(where:{$0.displayID==CGMainDisplayID()})!
            let config=SCStreamConfiguration();config.width=900;config.height=600;config.sourceRect=CGRect(x:100,y:100,width:900,height:600);config.showsCursor=false;config.minimumFrameInterval=CMTime(value:1,timescale:60);config.pixelFormat=kCVPixelFormatType_32BGRA;config.queueDepth=8
            let s=SCStream(filter:SCContentFilter(display:display,excludingWindows:[]),configuration:config,delegate:self);stream=s
            try s.addStreamOutput(self,type:.screen,sampleHandlerQueue:DispatchQueue(label:"test.screen",qos:.userInteractive));try await s.startCapture();record(["kind":"ready"])
        }catch{record(["kind":"error","message":String(describing:error)])}
    }
    func stream(_ stream:SCStream,didOutputSampleBuffer sample:CMSampleBuffer,of type:SCStreamOutputType){
        guard type == .screen,let pixel=sample.imageBuffer else{return}
        CVPixelBufferLockBaseAddress(pixel,.readOnly);defer{CVPixelBufferUnlockBaseAddress(pixel,.readOnly)}
        guard let base=CVPixelBufferGetBaseAddress(pixel)else{return}
        let row=CVPixelBufferGetBytesPerRow(pixel),w=CVPixelBufferGetWidth(pixel),h=CVPixelBufferGetHeight(pixel)
        var red=0,green=0,n=0
        for y in stride(from:80,to:h-30,by:15){for x in stride(from:30,to:w-30,by:15){let p=base.advanced(by:y*row+x*4).assumingMemoryBound(to:UInt8.self);n += 1;if p[2]>150&&p[1]<100{red += 1};if p[1]>120&&p[2]<100{green += 1}}}
        record(["kind":"frame","red":red,"green":green,"samples":n,"pts":CMTimeGetSeconds(sample.presentationTimeStamp)])
    }
}
FileManager.default.createFile(atPath:output,contents:Data())
let observer=Observer();let timer=DispatchSource.makeTimerSource(queue:DispatchQueue(label:"test.focus",qos:.userInteractive))
timer.schedule(deadline:.now(),repeating:.milliseconds(5));timer.setEventHandler{var pid:Int32=0;let status=dsh_key_focus_pid(&pid);record(["kind":"focus","key_focus_pid":pid,"status":status,"frontmost_pid":NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1])};timer.resume()
Task {await observer.start()}
RunLoop.main.run()
