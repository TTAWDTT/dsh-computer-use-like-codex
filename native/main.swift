import AppKit
import ApplicationServices

let app=NSApplication.shared
app.setActivationPolicy(.prohibited)
let driver=MainActor.assumeIsolated { Driver() }
@MainActor func response(_ request:Request)async->[String:Any]{
    do{
        let data:[String:Any]
        switch request.method {
        case "status":data=driver.status()
        case "apps":data=["windows":driver.windows()]
        case "observe":data=try await driver.observe(request.params)
        case "screenshot":
            let s=try driver.snapshot(request.params);var p=Parameters();p.pid=s.target.pid;p.window_id=s.target.id;p.include_image=true;p.max_elements=s.maxElements
            data=try await driver.observe(p)
        case "click","type","key","set_value","scroll","drag":
            var result=try await driver.action(request.method,request.params);result["id"]=request.id;return result
        default:throw DriverError(code:"UNKNOWN_METHOD",message:"Unknown method \(request.method)")
        }
        return ["id":request.id,"ok":true,"data":data]
    }catch let e as DriverError{return ["id":request.id,"ok":false,"error":["code":e.code,"message":e.message],"action_may_have_executed":e.actionExecuted,"retry_safe":false]}
    catch{return ["id":request.id,"ok":false,"error":["code":"DRIVER_ERROR","message":String(describing:error)],"retry_safe":false]}
}
signal(SIGTERM,SIG_IGN)
let termination=DispatchSource.makeSignalSource(signal:SIGTERM,queue:.main)
termination.setEventHandler { MainActor.assumeIsolated { driver.terminating=true;driver.cancelled=true; if !driver.busy {NSApp.terminate(nil)} } }
termination.resume()
signal(SIGUSR1,SIG_IGN)
let cancellation=DispatchSource.makeSignalSource(signal:SIGUSR1,queue:.main)
cancellation.setEventHandler {MainActor.assumeIsolated {if driver.busy {driver.cancelled=true}}}
cancellation.resume()
DispatchQueue.global(qos:.userInitiated).async {
    while let line=readLine(){
        let done=DispatchSemaphore(value:0)
        Task { @MainActor in
            let result:[String:Any]
            driver.busy=true
            driver.cancelled=false
            do{
                guard line.utf8.count<=1_000_000 else{throw DriverError(code:"INVALID_ARGUMENT",message:"Request exceeds 1 MB")}
                let request=try JSONDecoder().decode(Request.self,from:Data(line.utf8));result=await response(request)
            }catch{
                let id=(try? JSONSerialization.jsonObject(with:Data(line.utf8))) as? [String:Any]
                result=["id":id?["id"] ?? NSNull(),"ok":false,"error":["code":"INVALID_REQUEST","message":String(describing:error)]]
            }
            if let data=try? JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]) {FileHandle.standardOutput.write(data);FileHandle.standardOutput.write(Data([10]))}
            driver.busy=false
            done.signal()
            if driver.terminating {NSApp.terminate(nil)}
        }
        done.wait()
    }
    DispatchQueue.main.async{NSApp.terminate(nil)}
}
app.run()
