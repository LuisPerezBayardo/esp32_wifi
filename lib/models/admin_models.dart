class AdminPermissions {
  final bool canControlActuators;
  final bool canEditThresholds;
  final bool canManageDevices;
  final bool canManageUsers;
  final bool canViewAllPlants;
  final bool canExportData;

  const AdminPermissions({
    required this.canControlActuators,
    required this.canEditThresholds,
    required this.canManageDevices,
    required this.canManageUsers,
    required this.canViewAllPlants,
    required this.canExportData,
  });

  factory AdminPermissions.fromJson(Map<String, dynamic> j) => AdminPermissions(
        canControlActuators: j['canControlActuators'] == true,
        canEditThresholds: j['canEditThresholds'] == true,
        canManageDevices: j['canManageDevices'] == true,
        canManageUsers: j['canManageUsers'] == true,
        canViewAllPlants: j['canViewAllPlants'] == true,
        canExportData: j['canExportData'] == true,
      );

  Map<String, dynamic> toJson() => {
        'canControlActuators': canControlActuators,
        'canEditThresholds': canEditThresholds,
        'canManageDevices': canManageDevices,
        'canManageUsers': canManageUsers,
        'canViewAllPlants': canViewAllPlants,
        'canExportData': canExportData,
      };

  AdminPermissions copy() => AdminPermissions(
        canControlActuators: canControlActuators,
        canEditThresholds: canEditThresholds,
        canManageDevices: canManageDevices,
        canManageUsers: canManageUsers,
        canViewAllPlants: canViewAllPlants,
        canExportData: canExportData,
      );

  AdminPermissions copyWith({
    bool? canControlActuators,
    bool? canEditThresholds,
    bool? canManageDevices,
    bool? canManageUsers,
    bool? canViewAllPlants,
    bool? canExportData,
  }) =>
      AdminPermissions(
        canControlActuators: canControlActuators ?? this.canControlActuators,
        canEditThresholds: canEditThresholds ?? this.canEditThresholds,
        canManageDevices: canManageDevices ?? this.canManageDevices,
        canManageUsers: canManageUsers ?? this.canManageUsers,
        canViewAllPlants: canViewAllPlants ?? this.canViewAllPlants,
        canExportData: canExportData ?? this.canExportData,
      );
}

class AdminUser {
  final String id;
  final String email;
  final String firstName;
  final String lastName;
  final String role;
  final AdminPermissions permissions;

  AdminUser({
    required this.id,
    required this.email,
    required this.firstName,
    required this.lastName,
    required this.role,
    required this.permissions,
  });

  factory AdminUser.fromJson(Map<String, dynamic> j) => AdminUser(
        id: (j['_id'] ?? j['id'] ?? '').toString(),
        email: (j['email'] ?? '').toString(),
        firstName: (j['firstName'] ?? '').toString(),
        lastName: (j['lastName'] ?? '').toString(),
        role: (j['role'] ?? '').toString(),
        permissions: AdminPermissions.fromJson(Map<String, dynamic>.from(j['permissions'] ?? {})),
      );

  Map<String, dynamic> toJson() => {
        '_id': id,
        'email': email,
        'firstName': firstName,
        'lastName': lastName,
        'role': role,
        'permissions': permissions.toJson(),
      };
}

class AdminDeviceCreate {
  final String deviceId;
  final String name;
  final String plantId;
  final String chamberId;
  final String kind; // 'sensor' | 'actuator'

  AdminDeviceCreate({
    required this.deviceId,
    required this.name,
    required this.plantId,
    required this.chamberId,
    required this.kind,
  });

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'name': name,
        'plantId': plantId,
        'chamberId': chamberId,
        'kind': kind,
      };
}
