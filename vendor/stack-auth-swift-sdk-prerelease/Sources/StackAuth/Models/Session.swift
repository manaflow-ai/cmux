import Foundation

/// An active login session
public struct ActiveSession: Sendable {
    public let id: String
    public let userId: String
    public let createdAt: Date
    public let isImpersonation: Bool
    public let lastUsedAt: Date?
    public let isCurrentSession: Bool
    public let geoInfo: GeoInfo?
    
    init(from json: [String: Any]) {
        self.id = json["id"] as? String ?? ""
        self.userId = json["user_id"] as? String ?? ""
        
        // JSONSerialization returns NSNumber for numeric values, use doubleValue for reliable parsing
        let createdMillis = (json["created_at"] as? NSNumber)?.doubleValue ?? 0
        self.createdAt = Date(timeIntervalSince1970: createdMillis / 1000.0)
        
        self.isImpersonation = json["is_impersonation"] as? Bool ?? false
        
        if let lastUsedRaw = json["last_used_at"] as? NSNumber {
            self.lastUsedAt = Date(timeIntervalSince1970: lastUsedRaw.doubleValue / 1000.0)
        } else {
            self.lastUsedAt = nil
        }
        
        self.isCurrentSession = json["is_current_session"] as? Bool ?? false
        
        if let geoJson = json["last_used_at_end_user_ip_info"] as? [String: Any] ?? json["geo_info"] as? [String: Any] {
            self.geoInfo = GeoInfo(from: geoJson)
        } else {
            self.geoInfo = nil
        }
    }
}

/// Geographic information from IP address
public struct GeoInfo: Sendable {
    public let city: String?
    public let region: String?
    public let country: String?
    public let countryName: String?
    public let latitude: Double?
    public let longitude: Double?
    
    init(from json: [String: Any]) {
        self.city = json["city"] as? String
        self.region = json["region"] as? String
        self.country = json["country"] as? String
        self.countryName = json["country_name"] as? String
        self.latitude = json["latitude"] as? Double
        self.longitude = json["longitude"] as? Double
    }
}
