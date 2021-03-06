//
//  FetAPI.swift
//  FetLife
//
//  Created by Jose Cortinas on 2/3/16.
//  Copyright © 2016 BitLove Inc. All rights reserved.
//

import Foundation
import UIKit
import Alamofire
import AlamofireImage
import Freddy
import p2_OAuth2
import JWTDecode
import RealmSwift
import Realm
import WebKit

// MARK: - API Singleton

final class API {
    
    // Make this a singleton, accessed through sharedInstance
    static let sharedInstance = API()
    
    let baseURL: String
    let oauthSession: OAuth2CodeGrant
    var webViewProcessPool = WKProcessPool()
    
    private var memberId: String?
    private var memberNickname: String?
    var currentMember: Member? {
        didSet {
            if let m = currentMember {
                memberId = m.id
                memberNickname = m.nickname
                AppSettings.currentUserID = m.id
            } else {
                memberId = nil
                memberNickname = nil
                AppSettings.currentUserID = ""
            }
        }
    }
    
    class func isAuthorized() -> Bool {
        return sharedInstance.isAuthorized()
    }
    
    class func currentMemberId() -> String? {
        return sharedInstance.memberId
    }
    
    class func currentMemberNickname() -> String? {
        return sharedInstance.memberNickname
    }
    
    class func tryGettingAccessTokenIfNeeded(_ parameters: OAuth2StringDict?, withCallback callback: @escaping ((OAuth2JSON?) -> Void)) {
        
    }
    
    /// Authorizes the current user.
    ///
    /// - Parameters:
    ///   - context: Context of the authorization
    ///   - onAuthorize: Completion to run upon authorization
    class func authorizeInContext(_ context: AnyObject, onAuthorize: @escaping (_ parameters: OAuth2JSON?, _ error: Error?) -> Void) {
        guard isAuthorized() else {
//          sharedInstance.oauthSession.authorize(callback: onAuthorize)
//          sharedInstance.oauthSession.failure(callback: onFailure)
            
            // if we have a refresh token, try reauthorizing without having to log in again
//            if sharedInstance.oauthSession.refreshToken != nil {
//                sharedInstance.oauthSession.doRefreshToken(callback: onAuthorize)
//            } else {
            sharedInstance.oauthSession.authConfig.authorizeEmbeddedAutoDismiss = true
            sharedInstance.oauthSession.authConfig.ui.modalPresentationStyle = UIModalPresentationStyle.pageSheet
            sharedInstance.oauthSession.authConfig.ui.barTintColor = UIColor.backgroundColor()
            sharedInstance.oauthSession.authConfig.ui.controlTintColor = UIColor.brickColor()
            sharedInstance.oauthSession.authorizeEmbedded(from: context, callback: onAuthorize)
//            }
            
            
            return
        }
    }
    
    fileprivate init() {
        let info = Bundle.main.infoDictionary!
        
        self.baseURL = info["FETAPI_BASE_URL"] as! String
        
        let clientID = info["FETAPI_OAUTH_CLIENT_ID"] as! String
        let clientSecret = info["FETAPI_OAUTH_CLIENT_SECRET"] as! String
        
        oauthSession = OAuth2CodeGrant(settings: [
            "client_id": clientID,
            "client_secret": clientSecret,
            "authorize_uri": "\(baseURL)/oauth/authorize",
            "token_uri": "\(baseURL)/oauth/token",
            "scope": "",
            "redirect_uris": ["fetlifeapp://oauth/callback"],
            "verbose": false
        ] as OAuth2JSON)
        
        oauthSession.authConfig.ui.useSafariView = true
        oauthSession.authConfig.authorizeEmbedded = false
        oauthSession.authConfig.authorizeEmbeddedAutoDismiss = true
        
        if let accessToken = oauthSession.accessToken {
            do {
                let jwt = try decode(jwt: accessToken)
                
				if let userDictionary: Dictionary<String, Any> = jwt.body["user"] as? Dictionary<String, Any> {
                    self.memberId = userDictionary["id"] as? String
                    self.memberNickname = userDictionary["nick"] as? String
                }
            } catch(let error) {
                print(error)
            }
        }
    }
    
    /// Checks if the OAuth token is present and unexpired.
    ///
    /// - Returns: Boolean value indicating if the user is authorized
    func isAuthorized() -> Bool {
        // FIXME: - There's currently an issue where the OAuth token seems to be expired but a restart of the app makes it valid again. Although not quite as secure, this should hopefully rectify this issue.
        guard !oauthSession.hasUnexpiredAccessToken() else { return true }
        if let id = memberId {
            if AppSettings.currentUserID != "" && AppSettings.currentUserID == id { return true }
        }
        return false
    }
    
    /// Logs the user out of Fetlife by forgetting OAuth tokens and removing all fetlife cookies.
    func logout() {
        oauthSession.forgetTokens();
        let storage = HTTPCookieStorage.shared
        storage.cookies?.forEach() { storage.deleteCookie($0) }
        webViewProcessPool = WKProcessPool()
        let realm: Realm = try! Realm()
        try! realm.write {
            realm.deleteAll()
        }
        API.sharedInstance.webViewProcessPool = WKProcessPool() // reset process pool
        API.sharedInstance.currentMember = nil
        app.cancelAllLocalNotifications()
        AppSettings.currentUserID = ""
    }
    
    // MARK: - Conversation API
    
    private var conversationLoadAttempts: Int = 0
    /// Loads all the conversations for the current user.
    ///
    /// - Parameter completion: Optional completion with error
    func loadConversations(_ completion: ((_ error: Error?) -> Void)?) {
        let parameters = ["limit": 100, "order": "-updated_at", "with_archived": true] as [String : Any]
        let url = AppSettings.useAndroidAPI ? "https://app.fetlife.com/api/v2/me/conversations" : "\(baseURL)/v2/me/conversations"
        conversationLoadAttempts += 1
        oauthSession.request(.get, url, parameters: parameters).responseData { response -> Void in
            switch response.result {
            case .success(let value):
                do {
                    let json = try JSON(data: value).getArray()
                    if json.isEmpty {
                        self.conversationLoadAttempts = 0
                        completion?(nil)
                        return
                    }
                    
                    if let err: String = try? json[0].getString(at: "error") {
                        if err == "Forbidden" {
                            throw APIError.Forbidden
                        } else if err == "The maximum number of requests per minute has been exceeded" {
                            throw APIError.RateLimitExceeded
                        } else {
                            throw APIError.General(description: err)
                        }
                    }
                    
                    let realm = try! Realm()
                    if !realm.isInWriteTransaction {
                        var convos: [Conversation] = []
                        for c in json {
                            if let conversation = try? Conversation.init(json: c) {
                                let id = conversation.id
                                if let rConvo = try! Realm().objects(Conversation.self).filter("id == %@", id).first {
                                    if rConvo.updatedAt != conversation.updatedAt || rConvo.lastMessageCreated != conversation.lastMessageCreated || (rConvo.subject == "" && conversation.subject != "") {
                                        convos.append(conversation)
                                    } else {
                                        convos.append(rConvo)
                                    }
                                } else {
                                    convos.append(conversation)
                                }
                            }
                        }
                        
                            for c in convos {
                                c.updateMember()
                            }
                            do {
                                try realm.write { realm.add(convos, update: true) }
                            } catch let e {
                                print("Error writing conversations to Realm: \(e.localizedDescription)")
                            }
                            self.conversationLoadAttempts = 0
                            completion?(nil)
//                        }
                    } else if self.conversationLoadAttempts <= 10 {
                        print("Realm in write transaction! Will retry loading convos in \(self.conversationLoadAttempts)s...")
                        Dispatch.delay(Double(self.conversationLoadAttempts), closure: {
                            self.loadConversations(completion)
                        })
                    } else {
                        print("Too many consecutive failures! Perhaps Realm is stuck in a write transaction?")
                        completion?(RLMError.fail as? Error)
                    }
                } catch(let error) {
                    self.conversationLoadAttempts = 0
                    completion?(error)
                }
            case .failure(let error):
                print("Request error: \(error.localizedDescription)")
                self.conversationLoadAttempts = 0
                completion?(error)
            }
        }
    }
    
    private var archiveAttempts: Int = 0
    /// Archives the specified conversation.
    ///
    /// - Parameters:
    ///   - conversationId: ID of conversation to archive
    ///   - completion: Optional completion with error
    func archiveConversation(_ conversationId: String, completion: ((_ error: Error?) -> Void)?) {
        let parameters = ["is_archived": true]
        let url = "\(baseURL)/v2/me/conversations/\(conversationId)"
        
        archiveAttempts += 1
        oauthSession.request(.put, url, parameters: parameters).responseData { response -> Void in
            switch response.result {
            case .success(let value):
                do {
                    let json = try JSON(data: value)
                    
                    if let err: String = try? json.getString(at: "error") {
                        if err == "Forbidden" {
                            throw APIError.Forbidden
                        } else if err == "The maximum number of requests per minute has been exceeded" {
                            throw APIError.RateLimitExceeded
                        } else {
                            throw APIError.General(description: err)
                        }
                    }
                    
                    let conversation = try Conversation.init(json: json)
                    
                    let realm = try Realm()
                    if !realm.isInWriteTransaction {
                        try realm.write {
                            realm.add(conversation, update: true)
                        }
                        self.archiveAttempts = 0
                        completion?(nil)
                    } else if self.archiveAttempts <= 10 {
                        print("Realm in write transaction! Will retry in \(self.archiveAttempts)s...")
                        Dispatch.delay(Double(self.archiveAttempts), closure: {
                            self.archiveConversation(conversationId, completion: completion)
                        })
                    } else {
                        print("Too many consecutive failures! Perhaps Realm is stuck in a write transaction?")
                        self.archiveAttempts = 0
                        completion?(RLMError.fail as? Error)
                    }
                } catch(let error) {
                    self.archiveAttempts = 0
                    completion?(error)
                }
            case .failure(let error):
                self.archiveAttempts = 0
                completion?(error)
            }
        }
    }
    
    private var unarchiveAttempts: Int = 0
    /// Unarchives the specified conversation.
    ///
    /// - Parameters:
    ///   - conversationId: ID of conversation to unarchive
    ///   - completion: Optional completion with error
    func unarchiveConversation(_ conversationId: String, completion: ((_ error: Error?) -> Void)?) {
        let parameters = ["is_archived": false]
        let url = "\(baseURL)/v2/me/conversations/\(conversationId)"
        
        unarchiveAttempts += 1
        oauthSession.request(.put, url, parameters: parameters).responseData { response -> Void in
            switch response.result {
            case .success(let value):
                do {
                    let json = try JSON(data: value)
                    
                    let conversation = try Conversation.init(json: json)
                    
                    let realm = try Realm()
                    if !realm.isInWriteTransaction {
                        try realm.write {
                            realm.add(conversation, update: true)
                        }
                        self.unarchiveAttempts = 0
                        completion?(nil)
                    } else if self.unarchiveAttempts <= 10 {
                        print("Realm in write transaction! Will retry in \(self.unarchiveAttempts)s...")
                        Dispatch.delay(Double(self.unarchiveAttempts), closure: {
                            self.unarchiveConversation(conversationId, completion: completion)
                        })
                    } else {
                        print("Too many consecutive failures! Perhaps Realm is stuck in a write transaction?")
                        self.unarchiveAttempts = 0
                        completion?(RLMError.fail as? Error)
                    }
                } catch(let error) {
                    self.unarchiveAttempts = 0
                    completion?(error)
                }
            case .failure(let error):
                self.unarchiveAttempts = 0
                completion?(error)
            }
        }
    }
    
    private var deleteAttempts: Int = 0
    /// Deletes the specified conversation permanently.
    ///
    /// - Parameters:
    ///   - conversationId: ID of conversation to delete
    ///   - completion: Optional completion with error
    func deleteConversation(_ conversationId: String, completion: ((_ error: Error?) -> Void)?) {
        let url = "\(baseURL)/v2/me/conversations/\(conversationId)"
        
        deleteAttempts += 1
        oauthSession.request(.delete, url, parameters: [:]).responseData { response -> Void in
            switch response.result {
            case .success(let value):
                do {
                    print(value)
                    let realm = try Realm()
                    let conversation = realm.objects(Conversation.self).filter("id == %@", conversationId).first!
                    if !realm.isInWriteTransaction {
                        realm.beginWrite()
                        realm.delete(conversation)
                        try realm.commitWrite()
                        self.deleteAttempts = 0
                        
                        completion?(nil)
                    } else if self.deleteAttempts <= 10 {
                        print("Realm in write transaction! Will retry in \(self.deleteAttempts)s...")
                        Dispatch.delay(Double(self.deleteAttempts), closure: {
                            self.deleteConversation(conversationId, completion: completion)
                        })
                    } else {
                        print("Too many consecutive failures! Perhaps Realm is stuck in a write transaction?")
                        self.deleteAttempts = 0
                        completion?(RLMError.fail as? Error)
                    }
                } catch(let error) {
                    self.deleteAttempts = 0
                    completion?(error)
                }
            case .failure(let error):
                self.deleteAttempts = 0
                completion?(error)
            }
        }
    }
    
    private var messagesLoadAttempts: Int = 0
    /// Gets the messages in a conversation.
    ///
    /// - Parameters:
    ///   - conversationId: ID of conversation to load
    ///   - extraParameters: A dictionary of any additional parameters to send
    ///   - completion: Optional completion with error
    func loadMessages(_ conversationId: String, parameters extraParameters: Dictionary<String, Any> = [:], completion: ((_ error: Error?) -> Void)?) {
        let url = "\(baseURL)/v2/me/conversations/\(conversationId)/messages"
        var parameters: Dictionary<String, Any> = ["limit": 100 as Any]

        for (k, v) in extraParameters {
            parameters.updateValue(v, forKey: k)
        }
        messagesLoadAttempts += 1
        oauthSession.request(.get, url, parameters: parameters).responseData { response in
            switch response.result {
            case .success(let value):
                do {
                    let json = try JSON(data: value).getArray()
                    
                    if json.isEmpty {
                        self.messagesLoadAttempts = 0
                        completion?(nil)
                        return
                    }
                    
                    if let err: String = try? json[0].getString(at: "error") {
                        if err == "Forbidden" {
                            throw APIError.Forbidden
                        } else if err == "The maximum number of requests per minute has been exceeded" {
                            throw APIError.RateLimitExceeded
                        } else {
                            throw APIError.General(description: err)
                        }
                    }
                    
                    let realm = try! Realm()
                    if !realm.isInWriteTransaction {
                        var messages: [Message] = []
                        for m in json {
                            do {
                                let message = try Message.init(json: m)
                                message.conversationId = conversationId
                                messages.append(message)
                            } catch(let err as APIError) {
                                print(err)
                                if err == APIError.Forbidden {
                                    throw err
                                }
                            }
                        }
                        try realm.write { realm.add(messages, update: true) }
                        self.messagesLoadAttempts = 0
                        completion?(nil)
                    } else if self.messagesLoadAttempts <= 10 {
                        print("Realm in write transaction! Will retry loading messages in \(self.messagesLoadAttempts)s...")
                        Dispatch.delay(Double(self.messagesLoadAttempts), closure: {
                            self.loadMessages(conversationId, parameters: parameters, completion: completion)
                        })
                    } else {
                        print("Too many consecutive failures! Perhaps Realm is stuck in a write transaction?")
                        self.messagesLoadAttempts = 0
                        completion?(RLMError.fail as? Error)
                    }
                } catch(let error) {
                    self.messagesLoadAttempts = 0
                    completion?(error)
                }
            case .failure(let error):
                self.messagesLoadAttempts = 0
                completion?(error)
            }
        }
    }
    
    /// Creates a message in a conversation with the specified text.
    ///
    /// - Parameters:
    ///   - conversationId: The conversation ID
    ///   - messageBody: The text of the message
    func createAndSendMessage(_ conversationId: String, messageBody: String) {
        let parameters = ["body": messageBody]
        let url = "\(baseURL)/v2/me/conversations/\(conversationId)/messages"
        
        oauthSession.request(.post, url, parameters: parameters).responseData { response in
            switch response.result {
            case .success(let value):
                do {
                    let json = try JSON(data: value)
                    
                    let realm = try! Realm()
					let conversation: Conversation? = realm.object(ofType: Conversation.self, forPrimaryKey: conversationId as AnyObject)
                    let message = try Message(json: json)
                    
                    message.conversationId = conversationId
                    
                    try! realm.write {
                        conversation?.lastMessageBody = message.body
                        conversation?.lastMessageCreated = message.createdAt
						conversation?.lastMessageIsIncoming = false
                        realm.add(message)
                    }
                    
                } catch(let error) {
                    print(error)
                }
            case .failure(let error):
                print(error)
            }
        }
    }
    
    /// Marks a conversation as read.
    ///
    /// - Parameters:
    ///   - conversationId: ID of the conversation
    ///   - messageIds: Message(s) to mark as read
    ///   - completion: Optional completion closure with error
    func markMessagesAsRead(_ conversationId: String, messageIds: [String], completion: ((_ error: Error?) -> Void)?) {
        let parameters = ["ids": messageIds]
        let url = "\(baseURL)/v2/me/conversations/\(conversationId)/messages/read"
        
        oauthSession.request(.put, url, parameters: parameters).responseData { response in
            switch response.result {
            case .success:
                let realm = try! Realm()
                realm.refresh() // make sure Realm instance is the most recent version
                if let conversation = realm.object(ofType: Conversation.self, forPrimaryKey: conversationId as AnyObject) {
                    try! realm.write {
                        conversation.hasNewMessages = false
                        realm.add(conversation, update: true)
                    }
                }
                completion?(nil)
            case .failure(let error):
                print(error)
                completion?(error)
            }
        }
    }
    
    // MARK: - Profile API
    
    /// Gets the profile of the specified user.
    ///
    /// - Important: Do not use this to get the profile of the currently logged-in user. Instead, use getMe(_:).
    /// - Parameters:
    ///   - userID: ID of the user whose profile you wish to retrieve
    ///   - completion: Optional completion handler taking `JSON?` and `Error?` parameters
    func getFetUser(_ userID: String, completion: ((_ userInfo: JSON?, _ error: Error?) -> Void)?) {
        
        let url = AppSettings.useAndroidAPI ? "https://app.fetlife.com/api/v2/members/\(userID)" : "\(baseURL)/v2/members/\(userID)"
        
        oauthSession.request(.get, url, parameters: nil).responseData { response -> Void in
            switch response.result {
            case .success(let value):
                do {
                    let json: JSON = try JSON(data: value)
                    completion?(json, nil)
                } catch(let error) {
                    print("Error reading JSON data")
                    completion?(nil, error)
                }
            case .failure(let error):
                print("Error: \(error.localizedDescription)")
                completion?(nil, error)
            }
        }
    }
    
    /// Gets the logged-in user's profile information.
    ///
    /// - Parameter completion: Optional completion with error
    func getMe(_ completion: ((_ me: Member?, _ error: Error?) -> Void)?) {
        let parameters = [:] as [String : Any]
        let url = "\(baseURL)/v2/me"
        
        oauthSession.request(.get, url, parameters: parameters).responseData { response -> Void in
            switch response.result {
            case .success(let value):
                do {
                    let json = try JSON(data: value)
                    if json == nil {
                        completion?(nil, nil)
                        return
                    }
                    
                    let realm = try! Realm()
                    realm.beginWrite()
                    if let m = try? Member(json: json) {
                        API.sharedInstance.currentMember = m
                        completion?(m, nil)
                    } else {
                        completion?(nil, nil)
                    }
                    try! realm.commitWrite()
                    
                } catch(let error) {
                    completion?(nil, error)
                }
            case .failure(let error):
                completion?(nil, error)
            }
        }
    }
    
    // MARK: - Requests
    
    /// Gets any pending requests for the current user.
    ///
    /// - Parameters:
    ///   - limit: Integer describing the maximum number of requests to fetch (defaults to 100)
    ///   - page: Integer of the page requested (defaults to the first page)
    ///   - completion: Completion returning an array of `FriendRequest`s and an error
    func getRequests(_ limit: Int? = 100, page: Int? = 1, completion: ((_ requests: [FriendRequest], _ error: Error?) -> Void)?) {
        let url = "\(baseURL)/v2/me/friendrequests"
        let parameters: Dictionary<String, Any> = ["limit": limit as Any, "page": page as Any]
        
        oauthSession.request(.get, url, parameters: parameters).responseData { response -> Void in
            switch response.result {
            case .success(let value):
                do {
                    let json = try JSON(data: value).getArray()
                    
                    if json.isEmpty {
                        completion?([], nil)
                        return
                    }
                    
                    var requests: [FriendRequest] = []
                    for r in json {
                        if let newRequest = try? FriendRequest(json: r) {
                            requests.append(newRequest)
                        }
                    }
                    completion?(requests, nil)
                } catch(let error) {
                    completion?([], error)
                }
            case .failure(let error):
                completion?([], error)
            }
        }
    }
    
    
    // Extremely useful for making app store screenshots, keeping this around for now.
    func fakeConversations() -> JSON {
        return JSON.array([
            
            .dictionary([ // 1
                "id": .string("fake-convo-1"),
                "updated_at": .string("2016-03-11T02:29:27.000Z"),
                "member": .dictionary([
                    "id": .string("fake-member-1"),
                    "nickname": .string("JohnBaku"),
                    "meta_line": .string("38M Dom"),
                    "avatar": .dictionary([
                        "status": "sfw",
                        "variants": .dictionary(["medium": "https://flpics0.a.ssl.fastly.net/0/1/0005031f-846f-5022-a440-3bf29e0a649e_110.jpg"])
                    ])
                ]),
                "has_new_messages": .bool(true),
                "is_archived": .bool(false),
                "last_message": .dictionary([
                    "created_at": .string("2016-03-11T02:29:27.000Z"),
                    "body": .string("Welcome?! Welcome!"),
                    "member": .dictionary([
                        "id": .string("fake-member-1"),
                        "nickname": .string("JohnBaku"),
                    ])
                ])
            ]),
            
            .dictionary([ // 2
                "id": .string("fake-convo-2"),
                "updated_at": .string("2016-03-11T02:22:27.000Z"),
                "member": .dictionary([
                    "id": .string("fake-member-2"),
                    "nickname": .string("phoenix_flame"),
                    "meta_line": .string("24F Undecided"),
                    "avatar": .dictionary([
                        "status": "sfw",
                        "variants": .dictionary(["medium": "https://flpics2.a.ssl.fastly.net/729/729713/00051c06-0754-8b77-802c-c87e9632d126_110.jpg"])
                    ])
                ]),
                "has_new_messages": .bool(false),
                "is_archived": .bool(false),
                "last_message": .dictionary([
                    "created_at": .string("2016-03-11T02:22:27.000Z"),
                    "body": .string("Miss you!"),
                    "member": .dictionary([
                        "id": .string("fake-member-2"),
                        "nickname": .string("phoenix_flame"),
                    ])
                ])
            ]),
            
            .dictionary([ // 3
                "id": .string("fake-convo-3"),
                "updated_at": .string("2016-03-11T00:59:27.000Z"),
                "member": .dictionary([
                    "id": .string("fake-member-3"),
                    "nickname": .string("_jose_"),
                    "meta_line": .string("28M Evolving"),
                    "avatar": .dictionary([
                        "status": "sfw",
                        "variants": .dictionary(["medium": "https://flpics0.a.ssl.fastly.net/1568/1568309/0004c1d4-637c-8930-0e97-acf588a65176_110.jpg"])
                    ])
                ]),
                "has_new_messages": .bool(false),
                "is_archived": .bool(false),
                "last_message": .dictionary([
                    "created_at": .string("2016-03-11T00:59:27.000Z"),
                    "body": .string("I'm so glad :)"),
                    "member": .dictionary([
                        "id": .string("fake-member-3"),
                        "nickname": .string("_jose_"),
                    ])
                ])
            ]),
            
            .dictionary([ // 4
                "id": .string("fake-convo-4"),
                "updated_at": .string("2016-03-11T00:22:27.000Z"),
                "member": .dictionary([
                    "id": .string("fake-member-4"),
                    "nickname": .string("meowtacos"),
                    "meta_line": .string("24GF kitten"),
                    "avatar": .dictionary([
                        "status": "sfw",
                        "variants": .dictionary(["medium": "https://flpics1.a.ssl.fastly.net/3215/3215981/0005221b-36b5-8f8d-693b-4d695b78c947_110.jpg"])
                    ])
                ]),
                "has_new_messages": .bool(false),
                "is_archived": .bool(false),
                "last_message": .dictionary([
                    "created_at": .string("2016-03-11T00:22:27.000Z"),
                    "body": .string("That's awesome!"),
                    "member": .dictionary([
                        "id": .string("fake-member-4"),
                        "nickname": .string("meowtacos"),
                    ])
                ])
            ]),
            
            
            
            .dictionary([ // 5
                "id": .string("fake-convo-5"),
                "updated_at": .string("2016-03-10T20:41:27.000Z"),
                "member": .dictionary([
                    "id": .string("fake-member-5"),
                    "nickname": .string("hashtagbrazil"),
                    "meta_line": .string("30M Kinkster"),
                    "avatar": .dictionary([
                        "status": "sfw",
                        "variants": .dictionary(["medium": "https://flpics1.a.ssl.fastly.net/4634/4634686/000524af-28b0-c73d-d811-d67ae1b93019_110.jpg"])
                        
                    ])
                ]),
                "has_new_messages": .bool(false),
                "is_archived": .bool(false),
                "last_message": .dictionary([
                    "created_at": .string("2016-03-10T20:41:27.000Z"),
                    "body": .string("I love that design"),
                    "member": .dictionary([
                        "id": .string("fake-member-5"),
                        "nickname": .string("hashtagbrazil"),
                    ])
                ])
            ]),
            
            .dictionary([ // 6
                "id": .string("fake-convo-6"),
                "updated_at": .string("2016-03-10T01:10:27.000Z"),
                "member": .dictionary([
                    "id": .string("fake-member-6"),
                    "nickname": .string("BobRegular"),
                    "meta_line": .string("95GF"),
                    "avatar": .dictionary([
                        "status": "sfw",
                        "variants": .dictionary(["medium": "https://flpics1.a.ssl.fastly.net/978/978206/0004df12-b6be-f3c3-0ec5-b34d357957a3_110.jpg"])
                    ])
                ]),
                "has_new_messages": .bool(false),
                "is_archived": .bool(false),
                "last_message": .dictionary([
                    "created_at": .string("2016-03-10T01:10:27.000Z"),
                    "body": .string("Yes"),
                    "member": .dictionary([
                        "id": .string("fake-member-6"),
                        "nickname": .string("BobRegular"),
                    ])
                ])
            ]),
            
            .dictionary([ // 7
                "id": .string("fake-convo-7"),
                "updated_at": .string("2016-03-08T01:22:27.000Z"),
                "member": .dictionary([
                    "id": .string("fake-member-7"),
                    "nickname": .string("GothRabbit"),
                    "meta_line": .string("24 Brat"),
                    "avatar": .dictionary([
                        "status": "sfw",
                        "variants": .dictionary(["medium": "https://flpics2.a.ssl.fastly.net/4625/4625410/00052da5-9c1a-df4c-f3bd-530f944def18_110.jpg"])
                    ])
                ]),
                "has_new_messages": .bool(false),
                "is_archived": .bool(false),
                "last_message": .dictionary([
                    "created_at": .string("2016-03-08T01:22:27.000Z"),
                    "body": .string("Best munch ever"),
                    "member": .dictionary([
                        "id": .string("fake-member-7"),
                        "nickname": .string("JohnBaku"),
                    ])
                ])
            ]),
            
            .dictionary([ // 8
                "id": .string("fake-convo-8"),
                "updated_at": .string("2016-03-02T01:22:27.000Z"),
                "member": .dictionary([
                    "id": .string("fake-member-8"),
                    "nickname": .string("BiggleWiggleWiggle"),
                    "meta_line": .string("19 CEO"),
                    "avatar": .dictionary([
                        "status": "sfw",
                        "variants": .dictionary(["medium": "https://flpics0.a.ssl.fastly.net/0/1/0004c0a3-562e-7bf7-780e-6903293438a0_110.jpg"])
                    ])
                ]),
                "has_new_messages": .bool(false),
                "is_archived": .bool(false),
                "last_message": .dictionary([
                    "created_at": .string("2016-03-02T01:22:27.000Z"),
                    "body": .string("See ya"),
                    "member": .dictionary([
                        "id": .string("fake-member-8"),
                        "nickname": .string("BiggleWiggleWiggle"),
                    ])
                ])
            ])
        ])
    }
}
