class ResourceTokenizer
  def self.split(resource)
    tokenize(resource).map(&:last)
  end

  def self.tokenize(resource)
    result = []
    n = 0
    pn = 0
    state = :rt
    until n >= resource.length
      case state
      when :rt
        # looking for .
        if resource[n] == "."
          # reached the dot ..
          result << [:rt, resource[pn...n]]
          pn = n + 1
          state = :rn
        end
      when :rn
        # looking for [ or .
        if resource[n] == "."
          # reached the dot ..
          result << [:rn, resource[pn...n]]
          pn = n + 1
          state = :rt
        end
        if resource[n] == "["
          # reached the open bracket
          result << [:rn, resource[pn...n]]
          pn = n
          state = :ri
        end
        if n == resource.length - 1
          # last character .. close the current group
          # the last thing should only ever be an index or a name
          result << [:rn, resource[pn..n]]
          pn = n
          state = :done
        end
      when :ri
        # looking for ]
        if resource[n] == "]"
          # reached the close bracket
          result << [:ri, resource[pn..n]]
          pn = n + 1
          state = :rt
          if resource[n + 1] == "."
            pn = n + 2
            n += 1
          end
        end
      else
        warn "unhandled state: #{state.inspect}"
      end
      # p resource[n]
      n += 1
    end
    result
  end
end
