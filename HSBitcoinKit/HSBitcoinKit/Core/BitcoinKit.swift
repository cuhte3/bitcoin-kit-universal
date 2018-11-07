import Foundation
import HSHDWalletKit
import RealmSwift
import BigInt
import HSCryptoKit

public class BitcoinKit {

    public weak var delegate: BitcoinKitDelegate?

    private var unspentOutputsNotificationToken: NotificationToken?
    private var transactionsNotificationToken: NotificationToken?
    private var blocksNotificationToken: NotificationToken?

    private let difficultyEncoder: IDifficultyEncoder
    private let blockHelper: IBlockHelper
    private let validatorFactory: IBlockValidatorFactory

    private let network: INetwork

    private let realmFactory: IRealmFactory

    private let hdWallet: IHDWallet

    private let peerHostManager: IPeerHostManager
    private let stateManager: IStateManager
    private let initialSyncApi: IInitialSyncApi
    private let addressManager: IAddressManager
    private let bloomFilterManager: IBloomFilterManager

    private var peerGroup: IPeerGroup
    private let factory: IFactory

    private let initialSyncer: IInitialSyncer

    private let bech32AddressConverter: IBech32AddressConverter
    private let addressConverter: IAddressConverter
    private let scriptConverter: IScriptConverter
    private let transactionProcessor: ITransactionProcessor
    private let transactionExtractor: ITransactionExtractor
    private let transactionLinker: ITransactionLinker
    private let transactionSyncer: ITransactionSyncer
    private let transactionCreator: ITransactionCreator
    private let transactionBuilder: ITransactionBuilder
    private let blockchain: IBlockchain

    private let inputSigner: IInputSigner
    private let scriptBuilder: IScriptBuilder
    private let transactionSizeCalculator: ITransactionSizeCalculator
    private let unspentOutputSelector: IUnspentOutputSelector
    private let unspentOutputProvider: IUnspentOutputProvider

    private let blockSyncer: IBlockSyncer

    private var dataProvider: IDataProvider & BestBlockHeightDelegate

    public init(withWords words: [String], coin: Coin) {
        let wordsHash = words.joined().data(using: .utf8).map { CryptoKit.sha256($0).hex } ?? words[0]

        let realmFileName = "\(wordsHash)-\(coin.rawValue).realm"

        let documentsUrl = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let realmConfiguration = Realm.Configuration(fileURL: documentsUrl?.appendingPathComponent(realmFileName))

        difficultyEncoder = DifficultyEncoder()
        blockHelper = BlockHelper()
        validatorFactory = BlockValidatorFactory(difficultyEncoder: difficultyEncoder, blockHelper: blockHelper)

        scriptConverter = ScriptConverter()
        switch coin {
        case .bitcoin(let networkType):
            switch networkType {
            case .mainNet:
                network = BitcoinMainNet(validatorFactory: validatorFactory)
                bech32AddressConverter = SegWitBech32AddressConverter(scriptConverter: scriptConverter)
            case .testNet:
                network = BitcoinTestNet(validatorFactory: validatorFactory)
                bech32AddressConverter = SegWitBech32AddressConverter(scriptConverter: scriptConverter)
            case .regTest:
                network = BitcoinRegTest(validatorFactory: validatorFactory)
                bech32AddressConverter = SegWitBech32AddressConverter(scriptConverter: scriptConverter)
            }
        case .bitcoinCash(let networkType):
            switch networkType {
            case .mainNet:
                network = BitcoinCashMainNet(validatorFactory: validatorFactory, blockHelper: blockHelper)
                bech32AddressConverter = CashBech32AddressConverter()
            case .testNet, .regTest:
                network = BitcoinCashTestNet(validatorFactory: validatorFactory)
                bech32AddressConverter = CashBech32AddressConverter()
            }
        }
        addressConverter = AddressConverter(network: network, bech32AddressConverter: bech32AddressConverter)

        realmFactory = RealmFactory(configuration: realmConfiguration)

        hdWallet = HDWallet(seed: Mnemonic.seed(mnemonic: words), coinType: network.coinType, xPrivKey: network.xPrivKey, xPubKey: network.xPubKey)

        stateManager = StateManager(realmFactory: realmFactory)

        let addressSelector: IAddressSelector
        switch coin {
        case .bitcoin: addressSelector = BitcoinAddressSelector(addressConverter: addressConverter)
        case .bitcoinCash: addressSelector = BitcoinCashAddressSelector(addressConverter: addressConverter)
        }

        initialSyncApi = BtcComApi(network: network)

        peerHostManager = PeerHostManager(network: network, realmFactory: realmFactory)

        factory = Factory()
        bloomFilterManager = BloomFilterManager(realmFactory: realmFactory)
        peerGroup = PeerGroup(factory: factory, network: network, peerHostManager: peerHostManager, bloomFilterManager: bloomFilterManager)

        addressManager = AddressManager(realmFactory: realmFactory, hdWallet: hdWallet, addressConverter: addressConverter)
        initialSyncer = InitialSyncer(realmFactory: realmFactory, hdWallet: hdWallet, stateManager: stateManager, api: initialSyncApi, addressManager: addressManager, addressSelector: addressSelector, factory: factory, peerGroup: peerGroup, network: network)

        inputSigner = InputSigner(hdWallet: hdWallet, network: network)
        scriptBuilder = ScriptBuilder()

        transactionSizeCalculator = TransactionSizeCalculator()
        unspentOutputSelector = UnspentOutputSelector(calculator: transactionSizeCalculator)
        unspentOutputProvider = UnspentOutputProvider(realmFactory: realmFactory)

        transactionExtractor = TransactionExtractor(scriptConverter: scriptConverter, addressConverter: addressConverter)
        transactionLinker = TransactionLinker()
        transactionProcessor = TransactionProcessor(extractor: transactionExtractor, linker: transactionLinker, addressManager: addressManager)
        transactionSyncer = TransactionSyncer(realmFactory: realmFactory, processor: transactionProcessor, addressManager: addressManager, bloomFilterManager: bloomFilterManager)
        transactionBuilder = TransactionBuilder(unspentOutputSelector: unspentOutputSelector, unspentOutputProvider: unspentOutputProvider, transactionSizeCalculator: transactionSizeCalculator, addressConverter: addressConverter, inputSigner: inputSigner, scriptBuilder: scriptBuilder, factory: factory)
        transactionCreator = TransactionCreator(realmFactory: realmFactory, transactionBuilder: transactionBuilder, transactionProcessor: transactionProcessor, peerGroup: peerGroup, addressManager: addressManager)
        blockchain = Blockchain(network: network, factory: factory)

        dataProvider = DataProvider(realmFactory: realmFactory, addressManager: addressManager, addressConverter: addressConverter, transactionCreator: transactionCreator, transactionBuilder: transactionBuilder, network: network)
        blockSyncer = BlockSyncer(realmFactory: realmFactory, network: network, transactionProcessor: transactionProcessor, blockchain: blockchain, addressManager: addressManager, bloomFilterManager: bloomFilterManager)

        peerGroup.blockSyncer = blockSyncer
        peerGroup.transactionSyncer = transactionSyncer
        peerGroup.bestBlockHeightDelegate = dataProvider

        dataProvider.delegate = self
    }

}

extension BitcoinKit {

    public func start() throws {
        bloomFilterManager.regenerateBloomFilter()
        try initialSyncer.sync()
    }

    public func clear() throws {
        let realm = realmFactory.realm

        try realm.write {
            realm.deleteAll()
        }
    }

}

extension BitcoinKit {

    public var transactions: [TransactionInfo] {
        return dataProvider.transactions
    }

    public var lastBlockInfo: BlockInfo? {
        return dataProvider.lastBlockInfo
    }

    public var balance: Int {
        return dataProvider.balance
    }

    public func send(to address: String, value: Int) throws {
        try dataProvider.send(to: address, value: value)
    }

    public func validate(address: String) throws {
       try dataProvider.validate(address: address)
    }

    public func fee(for value: Int, toAddress: String? = nil, senderPay: Bool) throws -> Int {
        return try dataProvider.fee(for: value, toAddress: toAddress, senderPay: senderPay)
    }

    public var receiveAddress: String {
        return dataProvider.receiveAddress
    }

    public var debugInfo: String {
        return dataProvider.debugInfo
    }

}

extension BitcoinKit: DataProviderDelegate {

    func transactionsUpdated(inserted: [TransactionInfo], updated: [TransactionInfo], deleted: [Int]) {
        delegate?.transactionsUpdated(bitcoinKit: self, inserted: inserted, updated: updated, deleted: deleted)
    }

    func balanceUpdated(balance: Int) {
        delegate?.balanceUpdated(bitcoinKit: self, balance: balance)
    }

    func lastBlockInfoUpdated(lastBlockInfo: BlockInfo) {
        delegate?.lastBlockInfoUpdated(bitcoinKit: self, lastBlockInfo: lastBlockInfo)
    }

    func progressUpdated(progress: Double) {
        delegate?.progressUpdated(bitcoinKit: self, progress: progress)
    }

}

public protocol BitcoinKitDelegate: class {
    func transactionsUpdated(bitcoinKit: BitcoinKit, inserted: [TransactionInfo], updated: [TransactionInfo], deleted: [Int])
    func balanceUpdated(bitcoinKit: BitcoinKit, balance: Int)
    func lastBlockInfoUpdated(bitcoinKit: BitcoinKit, lastBlockInfo: BlockInfo)
    func progressUpdated(bitcoinKit: BitcoinKit, progress: Double)
}

extension BitcoinKit {

    public enum Coin {
        case bitcoin(network: Network)
        case bitcoinCash(network: Network)

        var rawValue: String {
            switch self {
            case .bitcoin(let network):
                return "btc-\(network)"
            case .bitcoinCash(let network):
                return "bch-\(network)"
            }
        }
    }

    public enum Network {
        case mainNet
        case testNet
        case regTest
    }

}