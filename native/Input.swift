import AppKit
import ApplicationServices

final class FocusMonitor {
    let original: NSRunningApplication?
    let target: Int32
    let initialKey: Int32?
    let pointer: CGPoint
    private let lock=NSLock()
    private let queue=DispatchQueue(label:"dsh.like-codex.focus",qos:.userInteractive)
    private var timer: DispatchSourceTimer?
    private var changed=false
    private var targetTookFocus=false
    private var records=[[String:Any]]()
    private var previousKey:Int32?
    private var previousFront:Int32?
    private var last=DispatchTime.now().uptimeNanoseconds
    private var maxGap:UInt64=0
    private var samples=0
    init(target:Int32){
        self.target=target;original=NSWorkspace.shared.frontmostApplication;initialKey=keyFocusPID();previousKey=initialKey;previousFront=original?.processIdentifier;pointer=CGEvent(source:nil)?.location ?? .zero
        let t=DispatchSource.makeTimerSource(queue:queue);timer=t
        t.schedule(deadline:.now(),repeating:.milliseconds(5))
        t.setEventHandler{[weak self]in self?.poll()};t.resume()
    }
    private func poll(){
        let key=keyFocusPID(),front=NSWorkspace.shared.frontmostApplication?.processIdentifier,now=DispatchTime.now().uptimeNanoseconds
        lock.lock();defer{lock.unlock()};samples += 1;maxGap=max(maxGap,now-last);last=now
        if key != previousKey || front != previousFront {
            if records.count<40 {records.append(["key_focus_pid":jsonOptional(key),"frontmost_pid":jsonOptional(front),"uptime_ns":now])}
            previousKey=key;previousFront=front;changed=true
            if original?.processIdentifier != target && initialKey != target && (key==target || front==target) {targetTookFocus=true}
        }
    }
    func checkpoint() throws {
        lock.lock();let interrupted=targetTookFocus;lock.unlock()
        if interrupted {throw DriverError(code:"FOCUS_CHANGED",message:"Target acquired system focus during background input. Stopped remaining events; observe before continuing.",actionExecuted:true)}
    }
    @MainActor func finish()->[String:Any]{
        timer?.cancel();queue.sync{};poll()
        let front=NSWorkspace.shared.frontmostApplication?.processIdentifier,key=keyFocusPID()
        var restored=false
        if original?.processIdentifier != target,(front==target || (front==original?.processIdentifier && key==target)),let original,!original.isTerminated {restored=original.activate(options:[])}
        lock.lock();defer{lock.unlock()}
        let afterPointer=CGEvent(source:nil)?.location ?? .zero
        return ["frontmost_before":jsonOptional(original?.processIdentifier),"frontmost_after":jsonOptional(front),"key_focus_before":jsonOptional(initialKey),"key_focus_after":jsonOptional(key),"samples":samples,"max_sample_gap_ms":Double(maxGap)/1e6,"observed_changes":records,"changed":changed,"target_took_focus":targetTookFocus,"restore_attempt_succeeded":restored,"pointer_before":[pointer.x,pointer.y],"pointer_after":[afterPointer.x,afterPointer.y]]
    }
}

extension Driver {
    func checkpoint(_ monitor:FocusMonitor)throws {
        if cancelled {throw DriverError(code:"CANCELLED",message:"Input cancelled; observe before continuing.",actionExecuted:true)}
        try monitor.checkpoint()
    }
    func mousePoint(_ p:Parameters,_ s:Snapshot)throws->CGPoint{
        if let index=p.element {guard let f=axFrame(try element(index,in:s))else{throw DriverError(code:"NO_CLICK_POINT",message:"Element has no bounds.")};return CGPoint(x:f.midX-s.target.frame.minX,y:f.midY-s.target.frame.minY)}
        let x=try required(p.x,"x"),y=try required(p.y,"y")
        guard x.isFinite,y.isFinite,x>=0,y>=0,x<s.target.frame.width*s.scale,y<s.target.frame.height*s.scale else{throw DriverError(code:"INVALID_ARGUMENT",message:"Coordinates must be inside the observed screenshot.")}
        return CGPoint(x:x/s.scale,y:y/s.scale)
    }
    func postMouse(_ type:NSEvent.EventType,_ point:CGPoint,_ s:Snapshot,button:String,count:Int,command:Bool,activationOnly:Bool=false)throws{
        let local=CGPoint(x:point.x,y:s.target.frame.height-point.y)
        guard let ns=NSEvent.mouseEvent(with:type,location:local,modifierFlags:command ? .command:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:Int(s.target.id),context:nil,eventNumber:0,clickCount:count,pressure:type == .leftMouseUp || type == .rightMouseUp ? 0:1),let event=ns.cgEvent else {throw DriverError(code:"EVENT_CREATION_FAILED",message:"Unable to create mouse event.")}
        event.location=CGPoint(x:s.target.frame.minX+point.x,y:s.target.frame.minY+point.y)
        event.setIntegerValueField(.eventTargetUnixProcessID,value:Int64(s.target.pid))
        event.setIntegerValueField(.mouseEventButtonNumber,value:button=="right" ? 1:0)
        if activationOnly {event.setIntegerValueField(.mouseEventSubtype,value:3)}
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer,value:Int64(s.target.id))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent,value:Int64(s.target.id))
        // CGEventSetWindowLocation uses a top-left origin, unlike NSEvent's location.
        guard dsh_set_event_window_location(event,point) else {throw DriverError(code:"UNSUPPORTED_BACKGROUND",message:"Private event window-location API unavailable; no foreground fallback.")}
        event.timestamp=DispatchTime.now().uptimeNanoseconds;event.postToPid(s.target.pid)
    }
    func activateVirtually(_ s:Snapshot)throws{
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == s.target.pid {return}
        if virtualKeyWindows[s.target.pid]==s.target.id {return}
        watchVirtualFocus(s.target.pid)
        guard let activation=NSEvent.otherEvent(with:.appKitDefined,location:.zero,modifierFlags:[.control,.option],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:Int(s.target.id),context:nil,subtype:1,data1:0,data2:0)?.cgEvent else {throw DriverError(code:"EVENT_CREATION_FAILED",message:"Cannot create application activation notification.")}
        activation.timestamp=DispatchTime.now().uptimeNanoseconds;activation.postToPid(s.target.pid)
        let activationPoint=CGPoint(x:s.target.frame.width/2,y:12)
        try postMouse(.leftMouseDown,activationPoint,s,button:"left",count:1,command:false,activationOnly:true)
        try postMouse(.leftMouseUp,activationPoint,s,button:"left",count:1,command:false,activationOnly:true)
        // Process focus notification has no window. Window bookkeeping is established before it.
        guard let type=NSEvent.EventType(rawValue:21),let focus=NSEvent.otherEvent(with:type,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:0,context:nil,subtype:Int16(bitPattern:0x8000),data1:0,data2:0)?.cgEvent else {throw DriverError(code:"EVENT_CREATION_FAILED",message:"Cannot create process focus notification.")}
        focus.timestamp=DispatchTime.now().uptimeNanoseconds;focus.postToPid(s.target.pid)
        virtualKeyWindows[s.target.pid]=s.target.id
    }
    private func watchVirtualFocus(_ pid:Int32) {
        if focusObservers[pid] != nil {return}
        var observer:AXObserver?
        let callback:AXObserverCallback={_,element,name,context in
            guard let context else{return}
            let driver=Unmanaged<Driver>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                var pid:Int32=0;_ = AXUIElementGetPid(element,&pid)
                if name as String == kAXApplicationDeactivatedNotification {driver.virtualKeyWindows.removeValue(forKey:pid)}
                else {var window:UInt32=0;_ = dsh_window_id(element,&window);if driver.virtualKeyWindows[pid] != window {driver.virtualKeyWindows.removeValue(forKey:pid)}}
            }
        }
        guard AXObserverCreate(pid,callback,&observer) == .success,let observer else{return}
        let app=AXUIElementCreateApplication(pid),context=Unmanaged.passUnretained(self).toOpaque()
        _ = AXObserverAddNotification(observer,app,kAXApplicationDeactivatedNotification as CFString,context)
        _ = AXObserverAddNotification(observer,app,kAXFocusedWindowChangedNotification as CFString,context)
        CFRunLoopAddSource(CFRunLoopGetMain(),AXObserverGetRunLoopSource(observer),.commonModes)
        focusObservers[pid]=observer
    }
    private func checkForegroundWindow(_ t:WindowTarget)throws {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier==t.pid else{return}
        guard let value=axValue(AXUIElementCreateApplication(t.pid),kAXFocusedWindowAttribute),CFGetTypeID(value)==AXUIElementGetTypeID()else{throw DriverError(code:"UNSUPPORTED_BACKGROUND",message:"Cannot identify this foreground app's focused window.")}
        var id:UInt32=0;_ = dsh_window_id((value as! AXUIElement),&id)
        guard id==t.id else{throw DriverError(code:"UNSUPPORTED_BACKGROUND",message:"A different window in the same foreground process has focus. This version refuses to retarget it.")}
    }
    func editable(_ p:Parameters,_ s:Snapshot)throws->AXUIElement{
        let e:AXUIElement
        if let index=p.element {e=try element(index,in:s)}
        else {guard let value=axValue(AXUIElementCreateApplication(s.target.pid),kAXFocusedUIElementAttribute),CFGetTypeID(value)==AXUIElementGetTypeID()else{throw DriverError(code:"NO_FOCUSED_ELEMENT",message:"Observe and specify a text field element.")};e=value as! AXUIElement}
        guard axString(e,kAXRoleAttribute) != "AXSecureTextField",axString(e,kAXSubroleAttribute) != "AXSecureTextField"else{throw DriverError(code:"SECURE_INPUT",message:"Secure text fields are not supported.")}
        return e
    }
    func postKey(_ code:CGKeyCode,down:Bool,flags:CGEventFlags,text:String?=nil,pid:Int32)throws{
        guard let event=CGEvent(keyboardEventSource:CGEventSource(stateID:.privateState),virtualKey:code,keyDown:down)else{throw DriverError(code:"EVENT_CREATION_FAILED",message:"Unable to create keyboard event.")}
        event.flags=flags
        if let text {let utf16=Array(text.utf16);event.keyboardSetUnicodeString(stringLength:utf16.count,unicodeString:utf16)}
        event.timestamp=DispatchTime.now().uptimeNanoseconds;event.postToPid(pid)
    }
    func postFlags(_ flags:CGEventFlags,pid:Int32)throws {
        guard let event=CGEvent(keyboardEventSource:CGEventSource(stateID:.privateState),virtualKey:55,keyDown:true)else{throw DriverError(code:"EVENT_CREATION_FAILED",message:"Cannot create modifier event.")}
        event.type = .flagsChanged;event.flags=flags;event.timestamp=DispatchTime.now().uptimeNanoseconds;event.postToPid(pid)
    }
    func action(_ method:String,_ p:Parameters)async throws->[String:Any]{
        let s=try snapshot(p)
        try checkForegroundWindow(s.target)
        guard keyFocusPID() != nil else {throw DriverError(code:"UNSUPPORTED_BACKGROUND",message:"System key-focus observation is unavailable. Input is disabled without a foreground fallback.")}
        snapshots.removeValue(forKey:s.id)
        let monitor=FocusMonitor(target:s.target.pid)
        var sent=false,route="",failure:DriverError?
        do{
            route=try await performInput(method,p,s,monitor,sent:&sent)
            try await Task.sleep(nanoseconds:80_000_000);try checkpoint(monitor)
        }catch let e as DriverError {failure=e}catch{failure=DriverError(code:"ACTION_FAILED",message:String(describing:error),actionExecuted:sent)}
        var data:[String:Any]?
        if failure==nil {
            var next=Parameters();next.pid=s.target.pid;next.window_id=s.target.id;next.include_image=p.include_image ?? false;next.max_elements=s.maxElements
            do {data=try await observe(next)}
            catch {failure=DriverError(code:"OBSERVATION_FAILED",message:"Action dispatched but post-action observation failed: \(error). Do not repeat the action without checking its effect.",actionExecuted:true)}
        }
        let focus=monitor.finish()
        if failure==nil,focus["target_took_focus"] as? Bool == true {failure=DriverError(code:"FOCUS_CHANGED",message:"Final focus sample detected that the background target acquired focus.",actionExecuted:sent)}
        if let failure {return ["ok":false,"error":["code":failure.code,"message":failure.message],"action_may_have_executed":sent || failure.actionExecuted,"retry_safe":false,"focus":focus]}
        data!["action"]=["route":route,"events_dispatched":sent];data!["focus"]=focus
        return ["ok":true,"data":data!]
    }
    private func performInput(_ method:String,_ p:Parameters,_ s:Snapshot,_ monitor:FocusMonitor,sent:inout Bool)async throws->String {
        var route=""
            switch method {
            case "click":
                let button=p.button ?? "left",count=p.count ?? 1
                guard ["left","right"].contains(button),(1...3).contains(count)else{throw DriverError(code:"INVALID_ARGUMENT",message:"button must be left/right; count must be 1...3.")}
                var pressed=false
                if let index=p.element,button=="left",count==1 {
                    let e=try element(index,in:s);var actions:CFArray?;_ = AXUIElementCopyActionNames(e,&actions)
                    let names=actions as? [String] ?? []
                    if let name=[kAXPickAction,kAXPressAction].first(where:{names.contains($0)}) {
                        sent=true
                        let status=AXUIElementPerformAction(e,name as CFString)
                        if status == .success{pressed=true;route="ax_\(name)"}
                        else if status != .actionUnsupported {throw DriverError(code:"AX_ACTION_FAILED",message:"AX action returned \(status.rawValue). Its outcome may be uncertain.",actionExecuted:true)}
                    }
                }
                if !pressed {
                    let point=try mousePoint(p,s),command=NSWorkspace.shared.frontmostApplication?.processIdentifier != s.target.pid
                    for n in 1...count {
                        try checkpoint(monitor);sent=true
                        try postMouse(button=="right" ? .rightMouseDown:.leftMouseDown,point,s,button:button,count:n,command:command)
                        // Always balance an accepted down, even if focus changed while holding it.
                        try await Task.sleep(nanoseconds:20_000_000)
                        try postMouse(button=="right" ? .rightMouseUp:.leftMouseUp,point,s,button:button,count:n,command:command)
                    }
                    route="pid_mouse"
                }
            case "type":
                let text=try required(p.text,"text")
                guard text.utf16.count<=2000 else{throw DriverError(code:"INVALID_ARGUMENT",message:"type is limited to 2000 UTF-16 units per call.")}
                let e=try editable(p,s);sent=true;try activateVirtually(s)
                if p.element != nil {
                    let status=AXUIElementSetAttributeValue(e,kAXFocusedAttribute as CFString,kCFBooleanTrue)
                    guard status == .success else{throw DriverError(code:"CANNOT_FOCUS_ELEMENT",message:"AX could not focus the field (\(status.rawValue)).",actionExecuted:true)}
                }
                try await Task.sleep(nanoseconds:40_000_000)
                var pid:Int32=0
                guard AXUIElementGetPid(e,&pid) == .success,pid>0 else {throw DriverError(code:"STALE_SNAPSHOT",message:"Focused element has no live target process.",actionExecuted:true)}
                for scalar in text.unicodeScalars {
                    try checkpoint(monitor)
                    let string=String(scalar),code:CGKeyCode=scalar.value==10 ? 36:scalar.value==9 ? 48:0
                    try postKey(code,down:true,flags:[],text:string,pid:pid)
                    try postKey(code,down:false,flags:[],text:string,pid:pid)
                    try await Task.sleep(nanoseconds:4_000_000)
                }
                route="pid_unicode_keyboard"
            case "key":
                let (code,flags)=try parseKey(required(p.key,"key"));sent=true;try activateVirtually(s)
                try await Task.sleep(nanoseconds:30_000_000);try checkpoint(monitor)
                let baseline=CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand,.maskShift,.maskControl,.maskAlternate])
                try postFlags(flags,pid:s.target.pid)
                defer {try? postFlags(baseline,pid:s.target.pid)}
                try postKey(code,down:true,flags:flags,pid:s.target.pid);try postKey(code,down:false,flags:flags,pid:s.target.pid);route="pid_shortcut"
            case "set_value":
                let e=try editable(p,s),text=try required(p.text,"text")
                sent=true
                let status=AXUIElementSetAttributeValue(e,kAXValueAttribute as CFString,text as CFString)
                guard status == .success else{throw DriverError(code:"AX_VALUE_FAILED",message:"AX value write failed (\(status.rawValue)).",actionExecuted:true)}
                route="ax_value"
            case "scroll":
                let point=try mousePoint(p,s),dx=p.delta_x ?? 0,dy=p.delta_y ?? 0
                guard abs(Int(dx))<=10000,abs(Int(dy))<=10000,dx != 0 || dy != 0 else{throw DriverError(code:"INVALID_ARGUMENT",message:"Scroll deltas must be nonzero and within ±10000 pixels.")}
                guard let event=CGEvent(scrollWheelEvent2Source:CGEventSource(stateID:.privateState),units:.pixel,wheelCount:2,wheel1:dy,wheel2:dx,wheel3:0)else{throw DriverError(code:"EVENT_CREATION_FAILED",message:"Cannot create scroll event.")}
                event.location=CGPoint(x:s.target.frame.minX+point.x,y:s.target.frame.minY+point.y)
                event.setIntegerValueField(.mouseEventWindowUnderMousePointer,value:Int64(s.target.id));event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent,value:Int64(s.target.id))
                guard dsh_set_event_window_location(event,point)else{throw DriverError(code:"UNSUPPORTED_BACKGROUND",message:"Window-local events unavailable.")}
                try checkpoint(monitor);sent=true;event.postToPid(s.target.pid);route="pid_scroll"
            case "drag":
                let from=try mousePoint(p,s),x=try required(p.to_x,"to_x"),y=try required(p.to_y,"to_y"),duration=p.duration_ms ?? 350
                guard x.isFinite,y.isFinite,x>=0,y>=0,x<s.target.frame.width*s.scale,y<s.target.frame.height*s.scale,(50...5000).contains(duration)else{throw DriverError(code:"INVALID_ARGUMENT",message:"Drag endpoint outside screenshot, or duration_ms not 50...5000.")}
                let to=CGPoint(x:x/s.scale,y:y/s.scale),steps=max(2,duration/16),command=NSWorkspace.shared.frontmostApplication?.processIdentifier != s.target.pid
                try checkpoint(monitor);sent=true;try postMouse(.leftMouseDown,from,s,button:"left",count:1,command:command)
                var last=from
                do{
                    for i in 1...steps {try await Task.sleep(nanoseconds:UInt64(duration/steps)*1_000_000);try checkpoint(monitor);let f=Double(i)/Double(steps);last=CGPoint(x:from.x+(to.x-from.x)*f,y:from.y+(to.y-from.y)*f);try postMouse(.leftMouseDragged,last,s,button:"left",count:1,command:command)}
                }catch{try? postMouse(.leftMouseUp,last,s,button:"left",count:1,command:command);throw error}
                try postMouse(.leftMouseUp,to,s,button:"left",count:1,command:command);route="pid_drag"
            default:throw DriverError(code:"UNKNOWN_METHOD",message:"Unknown action \(method)")
            }
        return route
    }

}
func parseKey(_ input:String)throws->(CGKeyCode,CGEventFlags){
    let parts=input.lowercased().split(separator:"+").map(String.init)
    guard let key=parts.last,!key.isEmpty else{throw DriverError(code:"INVALID_ARGUMENT",message:"Empty key.")}
    var flags:CGEventFlags=[]
    for modifier in parts.dropLast(){switch modifier{case "cmd","command","super":flags.insert(.maskCommand);case "ctrl","control":flags.insert(.maskControl);case "alt","option":flags.insert(.maskAlternate);case "shift":flags.insert(.maskShift);default:throw DriverError(code:"INVALID_ARGUMENT",message:"Unknown modifier \(modifier)")}}
    let keys:[String:CGKeyCode]=["a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,"1":18,"2":19,"3":20,"4":21,"6":22,"5":23,"=":24,"9":25,"7":26,"-":27,"8":28,"0":29,"]":30,"o":31,"u":32,"[":33,"i":34,"p":35,"return":36,"enter":36,"l":37,"j":38,"'":39,"k":40,";":41,"\\":42,",":43,"/":44,"n":45,"m":46,".":47,"tab":48,"space":49,"backspace":51,"delete":51,"escape":53,"esc":53,"home":115,"pageup":116,"forwarddelete":117,"end":119,"pagedown":121,"left":123,"right":124,"down":125,"up":126]
    guard let code=keys[key]else{throw DriverError(code:"UNSUPPORTED_KEY",message:"Unsupported key \(key). Text uses type; shortcuts use macOS key names.")}
    return (code,flags)
}
