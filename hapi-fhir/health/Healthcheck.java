// Docker healthcheck for HAPI FHIR (distroless image — no shell, JRE only).
// Compile: javac healthcheck.java
// Invoke:  java -cp /healthcheck Healthcheck
import java.net.HttpURLConnection;
import java.net.URI;

public class Healthcheck {
    public static void main(String[] args) throws Exception {
        var url = URI.create("http://localhost:8080/fhir/metadata").toURL();
        var conn = (HttpURLConnection) url.openConnection();
        conn.setConnectTimeout(5000);
        conn.setReadTimeout(5000);
        if (conn.getResponseCode() != 200) System.exit(1);
    }
}
