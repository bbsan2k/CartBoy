import ORSSerial
import Gibby

final class GBxCartridgeControllerClassic<Cartridge: Gibby.Cartridge>: GBxCartridgeController<Cartridge> where Cartridge.Platform == GameboyClassic {
    enum ReaderCommand: CustomDebugStringConvertible {
        case start
        case stop
        case `continue`
        case address(_ command: String, radix: Int, address: Int)
        case sleep(_ duration: UInt32)
        case write(bytes: Data)
        
        var debugDescription: String {
            var desc = ">>>:\t"
            var appendDataDesc = true
            switch self {
            case .start:
                desc += "START:\t"
            case .stop:
                desc += "STOP:\t"
            case .continue:
                desc += "CONT:\t"
            case .address(let command, let radix, let address):
                let addr = String(address, radix: radix, uppercase: true)
                desc += "ADDR: \(command);\(radix);\(addr)\t"
            case .sleep(let duration):
                desc += "SLEEP:\t\t\(duration)u"
                appendDataDesc = false
            case .write(bytes: let data):
                desc += "WRT: \(data.count)"
            }
            
            if (appendDataDesc) {
                desc += "\t[\(data.hexString(separator: "|"))]"
            }
            return desc
        }
        
        private var data: Data {
            switch self {
            case .start:
                return "R".data(using: .ascii)!
            case .stop:
                return "0".data(using: .ascii)!
            case .continue:
                return "1".data(using: .ascii)!
            case .address(let command, let radix, let address):
                let addr = String(address, radix: radix, uppercase: true)
                return "\(command)\(addr)\0".data(using: .ascii)!
            case .write(bytes: let data):
                return "W".data(using: .ascii)! + data
            default:
                return Data()
            }
        }
        
        fileprivate func send(to controller: GBxCartridgeControllerClassic) {
            if controller.printStacktrace {
                switch self {
                case .continue: ()
                default:
                    print(self)
                }
            }
            guard case .sleep(let duration) = self else {
                controller.reader.send(self.data)
                return
            }
            usleep(duration)
        }
    }
    
    /**
     */
    func send(_ command: ReaderCommand...) {
        command.forEach {
            $0.send(to: self)
        }
    }
    
    /**
     */
    @objc func portOperationWillBegin(_ operation: Operation) {
        guard let readOp = operation as? SerialPortOperation<GBxCartridgeController<Cartridge>> else {
            operation.cancel()
            return
        }
        
        if printStacktrace {
            print(#function, readOp.context)
        }
        
        let timeout: UInt32 = 250
        
        switch readOp.context {
        case .cartridge(let header, let intent):
            if printStacktrace {
                print(header)
            }
            switch intent {
            case .write:
                let callback = { [weak self] (data: Data) in
                    guard let reader = self?.reader else {
                        return
                    }
                    reader.send(data)
                }
                //--------------------------------------------------------------
                // Set 'Gameboy Mode'
                self.reader.send("G".data(using: .ascii)!)
                //--------------------------------------------------------------
                switch Cartridge.self  {
                case is AM29F016B.Type:
                    guard let flashController = self.flashController() as GBxCartridgeControllerClassic<AM29F016B>? else {
                        operation.cancel()
                        return
                    }
                    guard AM29F016B.prepare(forWritingTo: flashController) else {
                        operation.cancel()
                        return
                    }
                default:
                    // Unsupported flash carts get cancelled.
                    operation.cancel()
                    
                    /* temporary */
                    fatalError()
                }
            default: ()
            }
        case .header:
            self.toggleRAMMode(on: false)
            //------------------------------------------------------------------
            // 1. set the start address to be read (stopping first; '\0')
            let address = Int(Cartridge.Platform.headerRange.lowerBound)
            self.send(
                .sleep(timeout)
                , .address("\0A", radix: 16, address: address)
            )
        //------------------------------------------------------------------
        case .bank(let bank, let cartridge):
            guard let header = cartridge.header as? GameboyClassic.Cartridge.Header else {
                operation.cancel()
                return
            }
            //------------------------------------------------------------------
            // 1. stop sending
            // 2. switch the ROM bank
            // 3. set the start address to be read (stopping first; '\0')
            self.send(.stop)
            self.set(bank: bank, with: header)
            self.send(.address("\0A", radix: 16, address: bank > 1 ? 0x4000 : 0x0000))
        //------------------------------------------------------------------
        case .saveFile(let header, _):
            guard let header = header as? GameboyClassic.Cartridge.Header else {
                operation.cancel()
                return
            }
            //------------------------------------------------------------------
            if printStacktrace {
                print(header)
            }
            //--------------------------------------------------------------
            // MBC2 "fix"
            //--------------------------------------------------------------
            // MBC2 Fix (unknown why this fixes reading the ram, maybe has
            // to read ROM before RAM?). Read 64 bytes of ROM,
            // (really only 1 byte is required).
            //--------------------------------------------------------------
            // 1. set the start address to be read (stopping first; '\0')
            switch header.configuration {
            case .one, .two:
                self.send(.address("\0A", radix: 16, address: 0x0000), .start, .stop)
            default: (/* do nothing? */)
            }
            //--------------------------------------------------------------
            if case .one = header.configuration {
                // set the 'RAM' mode (MBC1-only)
                self.send(
                    .address("B", radix: 16, address: 0x6000)
                    , .sleep(timeout)
                    , .address("B", radix: 10, address: 1)
                )
            }
            //------------------------------------------------------------------
            self.toggleRAMMode(on: true)
        //------------------------------------------------------------------
        case .sram(let bank, _):
            //------------------------------------------------------------------
            // 1. stop sending
            // 2. switch the RAM bank (then timeout)
            // 3. set the start address to be read (stopping first; '\0')
            self.send(.stop)
            self.send(
                .address("B", radix: 16, address: 0x4000)
                , .sleep(timeout)
                , .address("B", radix: 10, address: bank)
            )
            self.send(
                .sleep(3000) // 'Bus-Timing 3000'! Fixes 'writeSave'?
                , .address("A", radix: 16, address: 0xA000)
            )
            //------------------------------------------------------------------
        }
    }
    
    /**
     */
    @objc func portOperationDidBegin(_ operation: Operation) {
        guard let readOp = operation as? SerialPortOperation<GBxCartridgeController<Cartridge>> else {
            operation.cancel()
            return
        }
        
        if printStacktrace {
            print(#function, readOp.context)
        }
        
        switch readOp.context {
        case .header:
            self.send(.start)
        case .bank:
            self.send(.start)
        case .sram(let bank, let context):
            switch context {
            case .saveFile(_, .read):
                self.send(.start)
            case .saveFile(let header, .write(let data)):
                let startAddress = bank * header.ramBankSize
                let endAddress   = startAddress.advanced(by: 64)
                let dataToWrite  = data[startAddress..<endAddress]
                self.send(.write(bytes: dataToWrite))
            default: (/* no-op */)
            }
        default: ()
        }
    }
    
    /**
     */
    @objc func portOperation(_ operation: Operation, didUpdate progress: Progress) {
        guard let readOp = operation as? SerialPortOperation<GBxCartridgeController<Cartridge>> else {
            operation.cancel()
            return
        }
        
        let pageSize = 64
        
        switch readOp.context {
        case .cartridge:
            fallthrough
        case .saveFile:
            if printProgress {
                print(".", terminator: "")
            }
        case .sram(let bank, saveFile: let context):
            if (Int(progress.completedUnitCount) % pageSize) == 0 {
                switch context {
                case .saveFile(_, .read):
                    self.send(.continue)
                case .saveFile(let header, .write(let data)):
                    let startAddress = (bank * header.ramBankSize) + Int(progress.completedUnitCount)
                    let endAddress   = startAddress.advanced(by: pageSize)
                    let dataToWrite  = data[startAddress..<endAddress]
                    self.send(.write(bytes: dataToWrite))
                default: ()
                }
            }
        default:
            if (Int(progress.completedUnitCount) % pageSize) == 0 {
                self.send(.continue)
            }
        }
    }
    
    /**
     */
    @objc func portOperationDidComplete(_ operation: Operation) {
        self.reader.delegate = nil
        
        guard let readOp = operation as? SerialPortOperation<GBxCartridgeController<Cartridge>> else {
            operation.cancel()
            return
        }
        
        if printStacktrace {
            print(#function, readOp.context)
        }
        
        switch readOp.context {
        case .cartridge:
            self.close()
        case .saveFile:
            self.toggleRAMMode(on: false)
            self.send(.stop)
            self.close()
        case .header:
            self.send(.stop)
            self.close()
        default: ()
        }
    }
    
    private func toggleRAMMode(on turnOn: Bool, timeout: UInt32 = 500) {
        self.send(
            .address("B", radix: 16, address: 0x0000)
            , .sleep(timeout)
            , .address("B", radix: 10, address: turnOn ? 0x0A: 0x00)
        )
    }
    
    private func set(bank: Int, with header: GameboyClassic.Cartridge.Header, timeout: UInt32 = 250) {
        if case .one = header.configuration {
            self.send(
                .address("B", radix: 16, address: 0x6000)
                , .sleep(timeout)
                , .address("B", radix: 10, address: 0)
            )
            
            self.send(
                .address("B", radix: 16, address: 0x4000)
                , .sleep(timeout)
                , .address("B", radix: 10, address: bank >> 5)
            )
            
            self.send(
                .address("B", radix: 16, address: 0x2000)
                , .sleep(timeout)
                , .address("B", radix: 10, address: bank & 0x1F)
            )
        }
        else {
            self.send(
                .address("B", radix: 16, address: 0x2100)
                , .sleep(timeout)
                , .address("B", radix: 10, address: bank)
            )
            if bank >= 0x100 {
                self.send(
                    .address("B", radix: 16, address: 0x3000)
                    , .sleep(timeout)
                    , .address("B", radix: 10, address: 1)
                )
            }
        }
    }
}

extension GBxCartridgeControllerClassic {
    func flashController<Cart: FlashCart>() -> GBxCartridgeControllerClassic<Cart>? {
        guard Cartridge.self is Cart.Type else {
            return nil
        }
        return (self as! GBxCartridgeControllerClassic<Cart>)
    }
}
