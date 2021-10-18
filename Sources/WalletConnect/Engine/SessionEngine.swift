import Foundation
import Combine

final class SessionEngine {
    var sequencesStore: SessionSequencesStore
    private let wcSubscriber: WCSubscribing
    private let relayer: WalletConnectRelaying
    private let crypto: Crypto
    private var isController: Bool
    private var metadata: AppMetadata
    var onSessionApproved: ((SessionType.Settled)->())?
    var onSessionPayloadRequest: ((SessionRequest)->())?
    var onSessionRejected: ((String, SessionType.Reason)->())?
    var onSessionDelete: ((String, SessionType.Reason)->())?
    private var publishers = [AnyCancellable]()
    private let logger: BaseLogger

    init(relay: WalletConnectRelaying,
         crypto: Crypto,
         subscriber: WCSubscribing,
         sequencesStore: SessionSequencesStore,
         isController: Bool,
         metadata: AppMetadata,
         logger: BaseLogger) {
        self.relayer = relay
        self.crypto = crypto
        self.metadata = metadata
        self.wcSubscriber = subscriber
        self.sequencesStore = sequencesStore
        self.isController = isController
        self.logger = logger
        setUpWCRequestHandling()
        restoreSubscriptions()
    }
    
    func approve(proposal: SessionType.Proposal, accounts: [String], completion: @escaping (Result<SessionType.Settled, Error>) -> Void) {
        logger.debug("Approve session")
        let privateKey = Crypto.X25519.generatePrivateKey()
        let selfPublicKey = privateKey.publicKey.toHexString()
        
        let pendingSession = SessionType.Pending(status: .responded,
                                                 topic: proposal.topic,
                                                 relay: proposal.relay,
                                                 self: SessionType.Participant(publicKey: selfPublicKey, metadata: metadata),
                                                 proposal: proposal)
        
        sequencesStore.create(topic: proposal.topic, sequenceState: .pending(pendingSession))
        wcSubscriber.setSubscription(topic: proposal.topic)
        
        let agreementKeys = try! Crypto.X25519.generateAgreementKeys(
            peerPublicKey: Data(hex: proposal.proposer.publicKey),
            privateKey: privateKey)
        let settledTopic = agreementKeys.sharedSecret.sha256().toHexString()
        let sessionState: SessionType.State = SessionType.State(accounts: accounts)
        let expiry = Int(Date().timeIntervalSince1970) + proposal.ttl
        let settledSession = SessionType.Settled(
            topic: settledTopic,
            relay: proposal.relay,
            self: SessionType.Participant(publicKey: selfPublicKey, metadata: metadata),
            peer: SessionType.Participant(publicKey: proposal.proposer.publicKey, metadata: proposal.proposer.metadata),
            permissions: pendingSession.proposal.permissions,
            expiry: expiry,
            state: sessionState)
        
        let approveParams = SessionType.ApproveParams(
            relay: proposal.relay,
            responder: SessionType.Participant(
                publicKey: selfPublicKey,
                metadata: metadata),
            expiry: expiry,
            state: sessionState)
        let approvalPayload = ClientSynchJSONRPC(method: .sessionApprove, params: .sessionApprove(approveParams))
        _ = try? relayer.publish(topic: proposal.topic, payload: approvalPayload) { [weak self] result in
            switch result {
            case .success:
                self?.crypto.set(agreementKeys: agreementKeys, topic: settledTopic)
                self?.crypto.set(privateKey: privateKey)
                self?.sequencesStore.update(topic: proposal.topic, newTopic: settledTopic, sequenceState: .settled(settledSession))
                self?.wcSubscriber.setSubscription(topic: settledTopic)
                self?.logger.debug("Success on wc_sessionApprove, published on topic: \(proposal.topic), settled topic: \(settledTopic)")
                completion(.success(settledSession))
            case .failure(let error):
                self?.logger.error(error)
                completion(.failure(error))
            }
        }
    }
    
    func reject(proposal: SessionType.Proposal, reason: SessionType.Reason) {
        let rejectParams = SessionType.RejectParams(reason: reason)
        let rejectPayload = ClientSynchJSONRPC(method: .sessionReject, params: .sessionReject(rejectParams))
        _ = try? relayer.publish(topic: proposal.topic, payload: rejectPayload) { [weak self] result in
            self?.logger.debug("Reject result: \(result)")
        }
    }
    
    func delete(topic: String, reason: SessionType.Reason) {
        logger.debug("Will delete session for reason: message: \(reason.message) code: \(reason.code)")
        sequencesStore.delete(topic: topic)
        wcSubscriber.removeSubscription(topic: topic)
        let clientSynchParams = ClientSynchJSONRPC.Params.sessionDelete(SessionType.DeleteParams(reason: reason))
        let request = ClientSynchJSONRPC(method: .sessionDelete, params: clientSynchParams)
        do {
            _ = try relayer.publish(topic: topic, payload: request) { [weak self] result in
                self?.logger.debug("Session Delete result: \(result)")
            }
        }  catch {
            logger.error(error)
        }
    }
    
    func proposeSession(settledPairing: PairingType.Settled, permissions: SessionType.Permissions) {
        guard let pendingSessionTopic = generateTopic() else {
            logger.debug("Could not generate topic")
            return
        }
        logger.debug("Propose Session on topic: \(pendingSessionTopic)")
        let privateKey = Crypto.X25519.generatePrivateKey()
        let publicKey = privateKey.publicKey.toHexString()
        crypto.set(privateKey: privateKey)
        let proposer = SessionType.Proposer(publicKey: publicKey, controller: isController, metadata: metadata)
        let signal = SessionType.Signal(method: "pairing", params: SessionType.Signal.Params(topic: settledPairing.topic))
        let proposal = SessionType.Proposal(topic: pendingSessionTopic, relay: settledPairing.relay, proposer: proposer, signal: signal, permissions: permissions, ttl: getDefaultTTL())
        let selfParticipant = SessionType.Participant(publicKey: publicKey, metadata: metadata)
        let pending = SessionType.Pending(status: .proposed, topic: pendingSessionTopic, relay: settledPairing.relay, self: selfParticipant, proposal: proposal)
        sequencesStore.create(topic: pendingSessionTopic, sequenceState: .pending(pending))
        wcSubscriber.setSubscription(topic: pendingSessionTopic)
        let request = PairingType.PayloadParams.Request(method: .sessionPropose, params: proposal)
        let pairingPayloadParams = PairingType.PayloadParams(request: request)
        let pairingPayloadRequest = ClientSynchJSONRPC(method: .pairingPayload, params: .pairingPayload(pairingPayloadParams))
        _ = try? relayer.publish(topic: settledPairing.topic, payload: pairingPayloadRequest) { [unowned self] result in
            switch result {
            case .success:
                logger.debug("Sent Session Proposal -  pub \(privateKey.publicKey.toHexString())")
                let pairingAgreementKeys = crypto.getAgreementKeys(for: settledPairing.topic)!
                crypto.set(agreementKeys: pairingAgreementKeys, topic: proposal.topic)
            case .failure(let error):
                logger.debug("Could not send session proposal error: \(error)")
            }
        }
    }
    
    func request(params: SessionType.PayloadRequestParams, completion: @escaping ((Result<JSONRPCResponse<AnyCodable>, Error>)->())) {
        guard let _ = sequencesStore.get(topic: params.topic) else {
            logger.debug("Could not find session for topic \(params.topic)")
            return
        }
        let request = SessionType.PayloadParams.Request(method: params.method, params: AnyCodable(params.params))
        let sessionPayloadParams = SessionType.PayloadParams(request: request, chainId: params.chainId)
        let sessionPayloadRequest = ClientSynchJSONRPC(method: .sessionPayload, params: .sessionPayload(sessionPayloadParams))

        relayer.publish(topic: params.topic, payload: sessionPayloadRequest) { [weak self] result in
            switch result {
            case .success(let response):
                completion(.success(response))
                self?.logger.debug("Sent Session Payload")
            case .failure(let error):
                self?.logger.debug("Could not send session payload, error: \(error)")
            }
        }
    }
    
    func respond(topic: String, response: JSONRPCResponse<AnyCodable>) {
        guard let _ = sequencesStore.get(topic: topic) else {
            logger.debug("Could not find session for topic \(topic)")
            return
        }
        relayer.publish(topic: topic, payload: response) { [weak self] result in
            switch result {
            case .success:
                self?.logger.debug("Sent Session Payload Response")
            case .failure(let error):
                self?.logger.debug("Could not send session payload, error: \(error)")
            }
        }
    }

    //MARK: - Private

    private func getDefaultTTL() -> Int {
        7 * Time.day
    }
    
    private func generateTopic() -> String? {
        var keyData = Data(count: 32)
        let result = keyData.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        if result == errSecSuccess {
            return keyData.toHexString()
        } else {
            logger.debug("Problem generating random bytes")
            return nil
        }
    }
    
    private func getDefaultPermissions() -> PairingType.ProposedPermissions {
        PairingType.ProposedPermissions(jsonrpc: PairingType.JSONRPC(methods: [PairingType.PayloadMethods.sessionPropose.rawValue]))
    }
    
    private func setUpWCRequestHandling() {
        wcSubscriber.onRequestSubscription = { [unowned self] subscriptionPayload in
            switch subscriptionPayload.clientSynchJsonRpc.params {
            case .sessionApprove(let approveParams):
                self.handleSessionApprove(approveParams, topic: subscriptionPayload.topic)
            case .sessionReject(let rejectParams):
                handleSessionReject(rejectParams, topic: subscriptionPayload.topic)
            case .sessionUpdate(_):
                fatalError("Not implemented")
            case .sessionUpgrade(_):
                fatalError("Not implemented")
            case .sessionDelete(let deleteParams):
                handleSessionDelete(deleteParams, topic: subscriptionPayload.topic)
            case .sessionPayload(let sessionPayloadParams):
                self.handleSessionPayload(payloadParams: sessionPayloadParams, topic: subscriptionPayload.topic, requestId: subscriptionPayload.clientSynchJsonRpc.id)
            default:
                fatalError("unexpected method type")
            }
        }
    }
    
    private func handleSessionDelete(_ deleteParams: SessionType.DeleteParams, topic: String) {
        guard let _ = sequencesStore.get(topic: topic) else {
            logger.debug("Could not find session for topic \(topic)")
            return
        }
        sequencesStore.delete(topic: topic)
        wcSubscriber.removeSubscription(topic: topic)
        onSessionDelete?(topic, deleteParams.reason)
    }
    
    private func handleSessionReject(_ rejectParams: SessionType.RejectParams, topic: String) {
        guard let _ = sequencesStore.get(topic: topic) else {
            logger.debug("Could not find session for topic \(topic)")
            return
        }
        sequencesStore.delete(topic: topic)
        wcSubscriber.removeSubscription(topic: topic)
        onSessionRejected?(topic, rejectParams.reason)
    }
    
    private func handleSessionPayload(payloadParams: SessionType.PayloadParams, topic: String, requestId: Int64) {
        let jsonRpcRequest = JSONRPCRequest<AnyCodable>(id: requestId, method: payloadParams.request.method, params: payloadParams.request.params)
        let sessionRequest = SessionRequest(topic: topic, request: jsonRpcRequest, chainId: payloadParams.chainId)
        do {
            try validatePayload(sessionRequest)
            onSessionPayloadRequest?(sessionRequest)
        } catch let error as WalletConnectError {
            logger.error(error)
            respond(error: error, requestId: jsonRpcRequest.id, topic: topic)
        } catch {}
    }
    
    private func respond(error: WalletConnectError, requestId: Int64, topic: String) {
        let errorResponse = JSONRPCError(code: error.code, message: error.message)
        relayer.publish(topic: topic, payload: errorResponse) { [weak self] result in
            switch result {
            case .success(let response):
                self?.logger.debug("successfully responded with error: \(error)")
            case .failure(let error):
                self?.logger.error(error)
            }
        }
    }

    private func validatePayload(_ sessionRequest: SessionRequest) throws {
        guard case .settled(let settledSession) = sequencesStore.get(topic: sessionRequest.topic) else {
                  throw WalletConnectError.noSequenceForTopic
              }
        if let chainId = sessionRequest.chainId {
            guard settledSession.permissions.blockchain.chains.contains(chainId) else {
                throw WalletConnectError.unAuthorizedTargetChain
            }
        }
        guard settledSession.permissions.jsonrpc.methods.contains(sessionRequest.request.method) else {
            throw WalletConnectError.unAuthorizedJsonRpcMethod
        }
    }
    
    private func handleSessionApprove(_ approveParams: SessionType.ApproveParams, topic: String) {
        logger.debug("Responder Client approved session on topic: \(topic)")
        guard case let .pending(pendingSession) = sequencesStore.get(topic: topic) else {
                  logger.error("Could not find pending session for topic: \(topic)")
            return
        }
        let selfPublicKey = Data(hex: pendingSession.`self`.publicKey)
        let privateKey = try! crypto.getPrivateKey(for: selfPublicKey)!
        let peerPublicKey = Data(hex: approveParams.responder.publicKey)
        let agreementKeys = try! Crypto.X25519.generateAgreementKeys(peerPublicKey: peerPublicKey, privateKey: privateKey)
        let settledTopic = agreementKeys.sharedSecret.sha256().toHexString()
        crypto.set(agreementKeys: agreementKeys, topic: settledTopic)
        let proposal = pendingSession.proposal
        let controllerKey = proposal.proposer.controller ? selfPublicKey.toHexString() : proposal.proposer.publicKey
        let controller = Controller(publicKey: controllerKey)
        let proposedPermissions = pendingSession.proposal.permissions
        let sessionPermissions = SessionType.Permissions(blockchain: proposedPermissions.blockchain, jsonrpc: proposedPermissions.jsonrpc, notifications: proposedPermissions.notifications, controller: controller)
        
        let settledSession = SessionType.Settled(
            topic: settledTopic,
            relay: approveParams.relay,
            self: SessionType.Participant(publicKey: selfPublicKey.toHexString(), metadata: metadata),
            peer: SessionType.Participant(publicKey: approveParams.responder.publicKey, metadata: approveParams.responder.metadata),
            permissions: sessionPermissions,
            expiry: approveParams.expiry,
            state: approveParams.state)
        
        sequencesStore.update(topic: proposal.topic, newTopic: settledTopic, sequenceState: .settled(settledSession))
        wcSubscriber.setSubscription(topic: settledTopic)
        wcSubscriber.removeSubscription(topic: proposal.topic)
        onSessionApproved?(settledSession)
    }
    
    private func restoreSubscriptions() {
        relayer.transportConnectionPublisher
            .sink { [unowned self] (_) in
                let topics = sequencesStore.getAll().map{$0.topic}
                topics.forEach{self.wcSubscriber.setSubscription(topic: $0)}
            }.store(in: &publishers)
    }
}
