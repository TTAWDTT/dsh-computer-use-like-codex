import AppKit
import ApplicationServices
import ScreenCaptureKit

struct WindowTarget {
    let pid: Int32
    let id: UInt32
    let ax: AXUIElement
    let frame: CGRect
    let title: String
    let app: NSRunningApplication
}
struct Snapshot {
    let id: String
    let target: WindowTarget
    let elements: [AXUIElement]
    let created: Date
    let scale: Double
    let maxElements: Int
}
@MainActor final class Driver {
    var snapshots: [String:Snapshot] = [:]
    var virtualKeyWindows: [Int32:UInt32] = [:]
    var focusObservers: [Int32:AXObserver] = [:]
    var cancelled=false
    var terminating=false
    var busy=false
    func status()->[String:Any] {
        let keyFocus=keyFocusPID()
        return ["version":"0.1.0","protocol":1,"accessibility":AXIsProcessTrusted(),"screen_recording":CGPreflightScreenCaptureAccess(),"window_binding":dsh_has_window_binding(),"event_window_location":dsh_has_event_location(),"key_focus_query_available":keyFocus != nil,"key_focus_pid":jsonOptional(keyFocus),"frontmost_pid":jsonOptional(NSWorkspace.shared.frontmostApplication?.processIdentifier),"platform":"macos","architecture":{
#if arch(arm64)
            "arm64"
#else
            "x86_64"
#endif
        }(),"background_only":true,"automatic_foreground_fallback":false]
    }
    func windows()->[[String:Any]] {
        let rows=CGWindowListCopyWindowInfo([.optionAll,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
        return rows.compactMap {row in
            guard (row[kCGWindowLayer as String] as? Int ?? 0)==0,let pid=row[kCGWindowOwnerPID as String] as? Int32,let id=row[kCGWindowNumber as String] as? UInt32,let app=NSRunningApplication(processIdentifier:pid),app.activationPolicy == .regular,let dict=row[kCGWindowBounds as String] as? [String:Any],let frame=CGRect(dictionaryRepresentation:dict as CFDictionary),frame.width>1,frame.height>1 else {return nil}
            return ["pid":pid,"window_id":id,"app":app.localizedName ?? "","bundle_id":app.bundleIdentifier ?? "","title":row[kCGWindowName as String] as? String ?? "","on_screen":row[kCGWindowIsOnscreen as String] as? Bool ?? false,"bounds":rectJSON(frame)]
        }
    }
    func resolve(_ p:Parameters)throws->WindowTarget {
        try requireAccessibility()
        let candidates=NSWorkspace.shared.runningApplications.filter {app in
            if let pid=p.pid {return app.processIdentifier==pid}
            guard let name=p.app else {return false}
            return app.bundleIdentifier==name || app.localizedName==name
        }
        guard candidates.count==1,let app=candidates.first else {throw DriverError(code:"APP_NOT_UNIQUE",message:"Specify a running app's exact bundle ID or PID from like_codex_apps.")}
        let application=AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application,2)
        let windows=axValue(application,kAXWindowsAttribute) as? [AXUIElement] ?? []
        let matches=windows.filter {w in
            var id:UInt32=0
            return dsh_window_id(w,&id)==0 && id != 0 && (p.window_id==nil || id==p.window_id)
        }
        guard matches.count==1,let w=matches.first else {throw DriverError(code:"WINDOW_NOT_UNIQUE",message:"Specify window_id for an app with multiple windows. No window was raised or restored.")}
        var id:UInt32=0;_ = dsh_window_id(w,&id)
        guard let frame=axFrame(w),frame.width>0,frame.height>0 else {throw DriverError(code:"WINDOW_UNAVAILABLE",message:"Window geometry is unavailable.")}
        return WindowTarget(pid:app.processIdentifier,id:id,ax:w,frame:frame,title:axString(w,kAXTitleAttribute),app:app)
    }
    func checkWindow(_ t:WindowTarget)throws {
        guard !t.app.isTerminated else {throw DriverError(code:"STALE_SNAPSHOT",message:"Target process exited. Observe again.")}
        guard axBool(t.ax,kAXMinimizedAttribute) != true else {throw DriverError(code:"WINDOW_MINIMIZED",message:"Window is minimized. Background mode will not restore it.")}
        var id:UInt32=0
        let status=dsh_window_id(t.ax,&id)
        if status == AXError.cannotComplete.rawValue {throw DriverError(code:"AX_UNRESPONSIVE",message:"Target did not respond to Accessibility. No input was sent; observe again after it responds.")}
        guard status==0,id==t.id else {throw DriverError(code:"STALE_SNAPSHOT",message:"Target window is no longer available. Observe again.")}
        let info=CGWindowListCopyWindowInfo(.optionIncludingWindow,t.id) as? [[String:Any]]
        guard info?.first?[kCGWindowIsOnscreen as String] as? Bool == true else {throw DriverError(code:"WINDOW_OFFSCREEN",message:"Window is off screen. Background mode will not reveal it or switch Spaces.")}
    }
    func snapshot(_ p:Parameters)throws->Snapshot {
        try requireAccessibility()
        let id=try required(p.snapshot_id,"snapshot_id")
        guard let s=snapshots[id],Date().timeIntervalSince(s.created)<=60 else {throw DriverError(code:"STALE_SNAPSHOT",message:"Snapshot expired or was consumed. Observe again.")}
        try checkWindow(s.target)
        guard let frame=axFrame(s.target.ax),abs(frame.minX-s.target.frame.minX)<1,abs(frame.minY-s.target.frame.minY)<1,abs(frame.width-s.target.frame.width)<1,abs(frame.height-s.target.frame.height)<1 else {throw DriverError(code:"STALE_SNAPSHOT",message:"Window moved or resized. Observe again before using its coordinates.")}
        return s
    }
    func element(_ index:Int,in s:Snapshot)throws->AXUIElement {
        guard s.elements.indices.contains(index)else{throw DriverError(code:"INVALID_ARGUMENT",message:"Element does not exist in this snapshot.")}
        let e=s.elements[index]
        guard axBool(e,kAXEnabledAttribute) != false else {throw DriverError(code:"ELEMENT_DISABLED",message:"Target element is disabled.")}
        return e
    }
    func observe(_ p:Parameters) async throws->[String:Any] {
        let t=try resolve(p);try checkWindow(t)
        let maxElements=p.max_elements ?? 250
        guard (1...1000).contains(maxElements)else{throw DriverError(code:"INVALID_ARGUMENT",message:"max_elements must be 1...1000")}
        var image:[String:Any]?
        let cocoaPoint=CGPoint(x:t.frame.midX,y:(NSScreen.screens.first?.frame.maxY ?? 0)-t.frame.midY)
        var scale=Double(NSScreen.screens.first(where:{$0.frame.contains(cocoaPoint)})?.backingScaleFactor ?? 1)
        if p.include_image ?? true {let captured=try await capture(t);image=captured.image;scale=captured.scale}
        var refs=[AXUIElement](), entries=[[String:Any]](), queue:[(AXUIElement,Int)]=[(t.ax,0)], cursor=0, visited=Set<AXUIElement>()
        while cursor<queue.count, refs.count<maxElements, cursor<4000 {
            let (e,depth)=queue[cursor];cursor += 1
            if !visited.insert(e).inserted {continue}
            let role=axString(e,kAXRoleAttribute),subrole=axString(e,kAXSubroleAttribute)
            var actions:CFArray?;_ = AXUIElementCopyActionNames(e,&actions)
            let label=[axString(e,kAXTitleAttribute),axString(e,kAXDescriptionAttribute),axString(e,kAXHelpAttribute)].first(where:{!$0.isEmpty}) ?? ""
            let secure=role=="AXSecureTextField" || subrole=="AXSecureTextField"
            let value=secure ? "[secure]" : axString(e,kAXValueAttribute)
            if e==t.ax || !label.isEmpty || !value.isEmpty || (actions as? [String])?.isEmpty == false || ["AXTextField","AXTextArea","AXComboBox"].contains(role) {
                let index=refs.count;refs.append(e)
                var row:[String:Any]=["element":index,"role":role,"label":String(label.prefix(300)),"value":String(value.prefix(1000)),"value_truncated":value.count>1000,"actions":actions as? [String] ?? [],"enabled":axBool(e,kAXEnabledAttribute) ?? true,"secure":secure]
                if let frame=axFrame(e){row["frame"]=rectJSON(CGRect(x:(frame.minX-t.frame.minX)*scale,y:(frame.minY-t.frame.minY)*scale,width:frame.width*scale,height:frame.height*scale))}
                entries.append(row)
            }
            if depth<25 {queue.append(contentsOf:(axValue(e,kAXChildrenAttribute) as? [AXUIElement] ?? []).map{($0,depth+1)})}
        }
        snapshots=snapshots.filter{Date().timeIntervalSince($0.value.created)<=60}
        let id=UUID().uuidString
        snapshots[id]=Snapshot(id:id,target:t,elements:refs,created:Date(),scale:scale,maxElements:maxElements)
        var result:[String:Any]=["snapshot_id":id,"expires_in_ms":60000,"window":["pid":t.pid,"window_id":t.id,"app":t.app.localizedName ?? "","bundle_id":t.app.bundleIdentifier ?? "","title":t.title,"bounds":rectJSON(t.frame),"pixel_scale":scale],"elements":entries,"coordinate_space":"window screenshot pixels, top-left origin","truncated":cursor<queue.count,"text":entries.map {"[\($0["element"]!)] \($0["role"]!) \($0["label"]!) \($0["value"]!)"}.joined(separator:"\n")]
        if let image {result["image"]=image}
        return result
    }
    func capture(_ t:WindowTarget) async throws -> (image:[String:Any],scale:Double) {
        guard CGPreflightScreenCaptureAccess() else {throw DriverError(code:"SCREEN_RECORDING_REQUIRED",message:"Grant Screen Recording to the driver host, or observe with include_image=false.")}
        let content=try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:false)
        guard let window=content.windows.first(where:{$0.windowID==t.id}),window.owningApplication?.processID==t.pid,window.isOnScreen else {throw DriverError(code:"WINDOW_OFFSCREEN",message:"Window is off screen. It will not be raised, restored, or moved to another Space.")}
        let filter=SCContentFilter(desktopIndependentWindow:window),config=SCStreamConfiguration()
        let scale=Double(filter.pointPixelScale)
        config.width=max(1,Int(window.frame.width*scale));config.height=max(1,Int(window.frame.height*scale))
        config.showsCursor=false;config.ignoreShadowsSingleWindow=true
        let cg=try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:config)
        let bitmap=NSBitmapImageRep(cgImage:cg)
        guard let png=bitmap.representation(using:.png,properties:[:])else{throw DriverError(code:"CAPTURE_FAILED",message:"PNG encoding failed.")}
        return (["base64":png.base64EncodedString(),"width":cg.width,"height":cg.height,"media_type":"image/png"],scale)
    }
}
