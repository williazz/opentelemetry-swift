/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation

/// Configuration object for session management settings.
///
/// Controls session behavior including timeout duration and expiration handling.
/// Sessions automatically expire after the specified timeout period of inactivity.
///
/// Example:
/// ```swift
/// // Direct initialization
/// let config = SessionConfig(sessionTimeout: 45 * 60) // 45 minutes
///
/// // Using builder pattern
/// let config = SessionConfig.builder()
///   .with(sessionTimeout: 45 * 60)
///   .build()
///
/// let manager = SessionManager(configuration: config)
/// ```
public struct SessionConfig {
  /// Duration in seconds after which a session expires if left inactive
  public let sessionTimeout: TimeInterval
  /// Session sample rate (0.0 to 1.0)
  public let sessionSampleRate: Double

  /// Creates a new session configuration
  /// - Parameter sessionTimeout: Duration in seconds after which a session expires if left inactive (default 30 minutes)
  /// - Parameter sessionSampleRate: Session sample rate from 0.0 to 1.0 (default 1.0)
  public init(sessionTimeout: TimeInterval = 30 * 60, sessionSampleRate: Double = 1.0) {
    self.sessionTimeout = sessionTimeout
    self.sessionSampleRate = sessionSampleRate
  }

  /// Default configuration with 30-minute session timeout
  public static let `default` = SessionConfig()
}

/// Builder for creating SessionConfig instances with a fluent API.
///
/// Provides a convenient way to configure session settings using method chaining.
///
/// Example:
/// ```swift
/// let config = SessionConfig.builder()
///   .with(sessionTimeout: 45 * 60)
///   .build()
/// ```
public class SessionConfigBuilder {
  public private(set) var sessionTimeout: TimeInterval = 30 * 60
  public private(set) var sessionSampleRate: Double = 1.0

  /// Sets the session timeout duration
  /// - Parameter sessionTimeout: Duration in seconds after which a session expires if left inactive
  /// - Returns: The builder instance for method chaining
  public func with(sessionTimeout: TimeInterval) -> Self {
    self.sessionTimeout = sessionTimeout
    return self
  }

  /// Sets the session sample rate
  /// - Parameter sessionSampleRate: Session sample rate from 0.0 to 1.0
  /// - Returns: The builder instance for method chaining
  public func with(sessionSampleRate: Double) -> Self {
    self.sessionSampleRate = sessionSampleRate
    return self
  }

  /// Builds the SessionConfig with the configured settings
  /// - Returns: A new SessionConfig instance
  public func build() -> SessionConfig {
    return SessionConfig(sessionTimeout: sessionTimeout, sessionSampleRate: sessionSampleRate)
  }
}

/// Extension to SessionConfig for builder pattern support
public extension SessionConfig {
  /// Creates a new SessionConfigBuilder instance
  /// - Returns: A new builder for creating SessionConfig
  static func builder() -> SessionConfigBuilder {
    return SessionConfigBuilder()
  }
}
