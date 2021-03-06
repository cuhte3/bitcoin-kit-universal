import Foundation

extension String {

    public var reversedData: Data? {
        return Data(hex: self).map { Data($0.reversed()) }
    }

}
