using Gee;
using Sqlite;

namespace Qlite {

public class Row {
    private string[] column_names;
    private HashMap<string, int> column_indexes;
    private int[] column_types;
    private string?[] text_values;
    private long[] int_values;
    private double[] real_values;

    internal Row(Statement stmt, string[] column_names, HashMap<string, int> column_indexes, int[] column_types) {
        this.column_names = column_names;
        this.column_indexes = column_indexes;
        this.column_types = column_types;
        text_values = new string?[column_types.length];
        int_values = new long[column_types.length];
        real_values = new double[column_types.length];
        for (int i = 0; i < column_types.length; i++) {
            switch (column_types[i]) {
                case TEXT:
                    text_values[i] = stmt.column_text(i);
                    break;
                case INTEGER:
                    int_values[i] = (long) stmt.column_int64(i);
                    break;
                case FLOAT:
                    real_values[i] = stmt.column_double(i);
                    break;
            }
        }
    }

    public T get<T>(Column<T> field) {
        return field[this];
    }

    private int index_of(string field, string? table) {
        string name = table != null ? @"$table.$field" : field;
        if (column_indexes.has_key(name)) return column_indexes[name];
        return -1;
    }

    public string? get_text(string field, string? table = null) {
        int index = index_of(field, table);
        if (index < 0 || column_types[index] != TEXT) return null;
        return text_values[index];
    }

    public long get_integer(string field, string? table = null) {
        int index = index_of(field, table);
        if (index < 0 || column_types[index] != INTEGER) return 0;
        return int_values[index];
    }

    public bool has_integer(string field, string? table = null) {
        int index = index_of(field, table);
        return index >= 0 && column_types[index] == INTEGER;
    }

    public double get_real(string field, string? table = null, double def = 0) {
        int index = index_of(field, table);
        if (index < 0 || column_types[index] != FLOAT) return def;
        return real_values[index];
    }

    public bool has_real(string field, string? table = null) {
        int index = index_of(field, table);
        return index >= 0 && column_types[index] == FLOAT;
    }

    public string to_string() {
        string ret = "{";
        for (int i = 0; i < column_names.length; i++) {
            if (ret.length > 1) ret += ", ";
            switch (column_types[i]) {
                case TEXT:
                    ret = @"$ret$(column_names[i]): \"$(text_values[i])\"";
                    break;
                case INTEGER:
                    ret = @"$ret$(column_names[i]): $(int_values[i])";
                    break;
                case FLOAT:
                    ret = @"$ret$(column_names[i]): $(real_values[i])";
                    break;
            }
        }
        return ret + "}";
    }
}

public class RowIterator {
    private Database db;
    private Statement stmt;
    private string[]? column_names = null;
    private HashMap<string, int>? column_indexes = null;
    private int[]? column_types = null;

    public RowIterator.from_query_builder(Database db, QueryBuilder query) {
        this.db = db;
        this.stmt = query.prepare();
    }

    public RowIterator(Database db, string sql, string[]? args = null) {
        this.db = db;
        this.stmt = db.prepare(sql);
        if (args != null) {
            for (int i = 0; i < args.length; i++) {
                stmt.bind_text(i + 1, args[i]);
            }
        }
    }

    public bool next() {
        int r = stmt.step();
        if (r == Sqlite.ROW) return true;
        if (r == Sqlite.DONE) return false;
        warning(@"SQLite error: $(db.errcode()) - $(db.errmsg())");
        return false;
    }

    public Row get() {
        if (column_names == null) {
            string[] names = new string[stmt.column_count()];
            int[] types = new int[stmt.column_count()];
            var indexes = new HashMap<string, int>();
            for (int i = 0; i < stmt.column_count(); i++) {
                if (stmt.column_origin_name(i) != null) {
                    names[i] = @"$(stmt.column_table_name(i)).$(stmt.column_origin_name(i))";
                } else {
                    names[i] = stmt.column_name(i);
                }
                indexes[names[i]] = i;
                types[i] = stmt.column_type(i);
            }
            column_names = names;
            column_indexes = indexes;
            column_types = types;
        }
        return new Row(stmt, (!)column_names, (!)column_indexes, (!)column_types);
    }

    public Row? get_next() {
        if (next()) return get();
        return null;
    }
}

public class RowOption {
    public Row? inner { get; private set; }

    public RowOption(Row? row) {
        this.inner = row;
    }

    public bool is_present() {
        return inner != null;
    }

    public T get<T>(Column<T> field, T def = null) {
        if (inner == null || field.is_null((!)inner)) return def;
        return field[(!)inner];
    }

    internal long get_integer(string field, long def = 0) {
        if (inner == null || !((!)inner).has_integer(field)) return def;
        return ((!)inner).get_integer(field);
    }
}

}
