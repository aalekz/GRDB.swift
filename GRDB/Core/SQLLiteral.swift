/// SQLLiteral is a type which support [SQL
/// Interpolation](https://github.com/groue/GRDB.swift/blob/master/Documentation/SQLInterpolation.md).
///
/// For example:
///
///     try dbQueue.write { db in
///         let name: String = ...
///         let id: Int64 = ...
///         let query: SQLLiteral = "UPDATE player SET name = \(name) WHERE id = \(id)"
///         try db.execute(literal: query)
///     }
public struct SQLLiteral {
    /// SQLLiteral is an array of elements which can be qualified with
    /// table aliases.
    enum Element {
        case sql(String, StatementArguments = StatementArguments())
        case subquery((SQLGenerationContext) throws -> String)
        // Cases below can be qualified with a table alias
        case expression(SQLExpression)
        case selectable(SQLSelectable)
        case orderingTerm(SQLOrderingTerm)
        
        fileprivate func sql(_ context: SQLGenerationContext) throws -> String {
            switch self {
            case let .sql(sql, arguments):
                if context.append(arguments: arguments) == false {
                    // We don't know how to look for `?` in sql and
                    // replace them with literals.
                    fatalError("Not implemented: turning an SQL parameter into an SQL literal value")
                }
                return sql
            case let .subquery(function):
                return try function(context)
            case let .expression(expression):
                return try expression.expressionSQL(context, wrappedInParenthesis: false)
            case let .selectable(selectable):
                return try selectable.resultColumnSQL(context)
            case let .orderingTerm(orderingTerm):
                return try orderingTerm.orderingTermSQL(context)
            }
        }
        
        fileprivate func qualified(with alias: TableAlias) -> Element {
            switch self {
            case .sql:
                // Can't qualify raw SQL string
                return self
            case .subquery:
                // Subqueries don't need table alias
                return self
            case let .expression(expression):
                return .expression(expression.qualifiedExpression(with: alias))
            case let .selectable(selectable):
                return .selectable(selectable.qualifiedSelectable(with: alias))
            case let .orderingTerm(orderingTerm):
                return .orderingTerm(orderingTerm.qualifiedOrdering(with: alias))
            }
        }
    }
    
    private(set) var elements: [Element]
    
    init(elements: [Element]) {
        self.elements = elements
    }
    
    /// Creates an SQLLiteral from a plain SQL string, and eventual arguments.
    ///
    /// For example:
    ///
    ///     let query = SQLLiteral(
    ///         sql: "UPDATE player SET name = ? WHERE id = ?",
    ///         arguments: [name, id])
    public init(sql: String, arguments: StatementArguments = StatementArguments()) {
        self.init(elements: [.sql(sql, arguments)])
    }
    
    /// Creates an SQLLiteral from an SQL expression.
    ///
    /// For example:
    ///
    ///     let columnLiteral = SQLLiteral(Column("username"))
    ///     let suffixLiteral = SQLLiteral("@example.com".databaseValue)
    ///     let emailLiteral = [columnLiteral, suffixLiteral].joined(separator: " || ")
    ///     let request = User.select(emailLiteral.sqlExpression)
    ///     let emails = try String.fetchAll(db, request)
    public init(_ expression: SQLExpression) {
        self.init(elements: [.expression(expression)])
    }
    
    /// Turn a SQLLiteral into raw SQL and arguments.
    ///
    /// - parameter db: A database connection.
    /// - returns: A tuple made of a raw SQL string, and statement arguments.
    public func build(_ db: Database) throws -> (sql: String, arguments: StatementArguments) {
        let context = SQLGenerationContext(db)
        let sql = try self.sql(context)
        return (sql: sql, arguments: context.arguments)
    }
    
    func sql(_ context: SQLGenerationContext) throws -> String {
        try elements.map { try $0.sql(context) }.joined()
    }
    
    fileprivate func qualified(with alias: TableAlias) -> SQLLiteral {
        SQLLiteral(elements: elements.map { $0.qualified(with: alias) })
    }
}

extension SQLLiteral {
    /// Returns the SQLLiteral produced by the concatenation of two literals.
    ///
    ///     let name = "O'Brien"
    ///     let selection: SQLLiteral = "SELECT * FROM player "
    ///     let condition: SQLLiteral = "WHERE name = \(name)"
    ///     let query = selection + condition
    public static func + (lhs: SQLLiteral, rhs: SQLLiteral) -> SQLLiteral {
        var result = lhs
        result += rhs
        return result
    }
    
    /// Appends an SQLLiteral to the receiver.
    ///
    ///     let name = "O'Brien"
    ///     var query: SQLLiteral = "SELECT * FROM player "
    ///     query += "WHERE name = \(name)"
    public static func += (lhs: inout SQLLiteral, rhs: SQLLiteral) {
        lhs.elements += rhs.elements
    }
    
    /// Appends an SQLLiteral to the receiver.
    ///
    ///     let name = "O'Brien"
    ///     var query: SQLLiteral = "SELECT * FROM player "
    ///     query.append(literal: "WHERE name = \(name)")
    public mutating func append(literal sqlLiteral: SQLLiteral) {
        self += sqlLiteral
    }
    
    /// Appends a plain SQL string to the receiver, and eventual arguments.
    ///
    ///     let name = "O'Brien"
    ///     var query: SQLLiteral = "SELECT * FROM player "
    ///     query.append(sql: "WHERE name = ?", arguments: [name])
    public mutating func append(sql: String, arguments: StatementArguments = StatementArguments()) {
        self += SQLLiteral(sql: sql, arguments: arguments)
    }
}

extension SQLLiteral {
    /// Creates a literal SQL expression.
    ///
    ///     SQLLiteral(sql: "1 + 2").sqlExpression
    ///     SQLLiteral(sql: "? + ?", arguments: [1, 2]).sqlExpression
    ///     SQLLiteral(sql: ":one + :two", arguments: ["one": 1, "two": 2]).sqlExpression
    public var sqlExpression: SQLExpression {
        _SQLExpressionLiteral(sqlLiteral: self)
    }
    
    var sqlSelectable: SQLSelectable {
        _SQLSelectionLiteral(sqlLiteral: self)
    }
    
    var sqlOrderingTerm: SQLOrderingTerm {
        _SQLOrderingLiteral(sqlLiteral: self)
    }
}

extension Sequence where Element == SQLLiteral {
    /// Returns the concatenated SQLLiteral of this sequence of literals,
    /// inserting the given separator between each element.
    ///
    ///     let components: [SQLLiteral] = [
    ///         "UPDATE player",
    ///         "SET name = \(name)",
    ///         "WHERE id = \(id)"
    ///     ]
    ///     let query = components.joined(separator: " ")
    public func joined(separator: String = "") -> SQLLiteral {
        if separator.isEmpty {
            return SQLLiteral(elements: flatMap(\.elements))
        } else {
            return SQLLiteral(elements: Array(map(\.elements).joined(separator: CollectionOfOne(.sql(separator)))))
        }
    }
}

extension Collection where Element == SQLLiteral {
    /// Returns the concatenated SQLLiteral of this collection of literals,
    /// inserting the given SQL separator between each element.
    ///
    ///     let components: [SQLLiteral] = [
    ///         "UPDATE player",
    ///         "SET name = \(name)",
    ///         "WHERE id = \(id)"
    ///     ]
    ///     let query = components.joined(separator: " ")
    public func joined(separator: String = "") -> SQLLiteral {
        if separator.isEmpty {
            return SQLLiteral(elements: flatMap(\.elements))
        } else {
            return SQLLiteral(elements: Array(map(\.elements).joined(separator: CollectionOfOne(.sql(separator)))))
        }
    }
}

// MARK: - ExpressibleByStringInterpolation

extension SQLLiteral: ExpressibleByStringInterpolation {
    /// :nodoc
    public init(unicodeScalarLiteral: String) {
        self.init(sql: unicodeScalarLiteral, arguments: [])
    }
    
    /// :nodoc:
    public init(extendedGraphemeClusterLiteral: String) {
        self.init(sql: extendedGraphemeClusterLiteral, arguments: [])
    }
    
    /// :nodoc:
    public init(stringLiteral: String) {
        self.init(sql: stringLiteral, arguments: [])
    }
    
    /// :nodoc:
    public init(stringInterpolation sqlInterpolation: SQLInterpolation) {
        self.init(elements: sqlInterpolation.elements)
    }
}

// MARK: - _SQLExpressionLiteral

/// [**Experimental**](http://github.com/groue/GRDB.swift#what-are-experimental-features)
///
/// SQLExpressionLiteral is an expression built from a raw SQL snippet.
///
///     SQLExpressionLiteral(sql: "1 + 2")
///
/// The SQL literal may contain `?` and colon-prefixed arguments:
///
///     SQLExpressionLiteral(sql: "? + ?", arguments: [1, 2])
///     SQLExpressionLiteral(sql: ":one + :two", arguments: ["one": 1, "two": 2])
private struct _SQLExpressionLiteral: SQLExpression {
    private let sqlLiteral: SQLLiteral
    
    // Prefer SQLLiteral.sqlExpression
    init(sqlLiteral: SQLLiteral) {
        self.sqlLiteral = sqlLiteral
    }
    
    /// [**Experimental**](http://github.com/groue/GRDB.swift#what-are-experimental-features)
    /// :nodoc:
    func expressionSQL(_ context: SQLGenerationContext, wrappedInParenthesis: Bool) throws -> String {
        if wrappedInParenthesis {
            return try "(\(expressionSQL(context, wrappedInParenthesis: false)))"
        }
        return try sqlLiteral.sql(context)
    }
    
    /// [**Experimental**](http://github.com/groue/GRDB.swift#what-are-experimental-features)
    /// :nodoc:
    func qualifiedExpression(with alias: TableAlias) -> SQLExpression {
        sqlLiteral.qualified(with: alias).sqlExpression
    }
}

// MARK: - _SQLSelectionLiteral

private struct _SQLSelectionLiteral: SQLSelectable {
    private let sqlLiteral: SQLLiteral
    
    // Prefer SQLLiteral.sqlSelectable
    fileprivate init(sqlLiteral: SQLLiteral) {
        self.sqlLiteral = sqlLiteral
    }
    
    func resultColumnSQL(_ context: SQLGenerationContext) throws -> String {
        try sqlLiteral.sql(context)
    }
    
    func countedSQL(_ context: SQLGenerationContext) throws -> String {
        fatalError("""
            Selection literals can't be counted. \
            To resolve this error, select one or several literal expressions instead. \
            See SQLLiteral.sqlExpression.
            """)
    }
    
    func count(distinct: Bool) -> SQLCount? {
        fatalError("""
            Selection literals can't be counted. \
            To resolve this error, select one or several literal expressions instead. \
            See SQLLiteral.sqlExpression.
            """)
    }
    
    func columnCount(_ db: Database) throws -> Int {
        fatalError("""
            Selection literals don't known how many columns they contain. \
            To resolve this error, select one or several literal expressions instead. \
            See SQLLiteral.sqlExpression.
            """)
    }
    
    func qualifiedSelectable(with alias: TableAlias) -> SQLSelectable {
        sqlLiteral.qualified(with: alias).sqlSelectable
    }
}

// MARK: - _SQLOrderingLiteral

private struct _SQLOrderingLiteral: SQLOrderingTerm {
    private let sqlLiteral: SQLLiteral
    
    // Prefer SQLLiteral.sqlOrderingTerm
    fileprivate init(sqlLiteral: SQLLiteral) {
        self.sqlLiteral = sqlLiteral
    }
    
    var reversed: SQLOrderingTerm {
        fatalError("""
            Ordering literals can't be reversed. \
            To resolve this error, order by expression literals instead.
            """)
    }
    
    func orderingTermSQL(_ context: SQLGenerationContext) throws -> String {
        try sqlLiteral.sql(context)
    }
    
    func qualifiedOrdering(with alias: TableAlias) -> SQLOrderingTerm {
        sqlLiteral.qualified(with: alias).sqlOrderingTerm
    }
}
